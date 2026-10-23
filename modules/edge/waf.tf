# The distribution serves IPv6, and browsers prefer it, so every allow-list
# needs an IPv4 and an IPv6 set (a WAF IP set can't mix the two).
locals {
  ip_sets = {
    admin = {
      description = "Networks allowed to reach wp-admin / wp-login"
      cidrs       = var.admin_allowed_cidrs
    }
    rate-exempt = {
      description = "Load-test runners exempt from the per-IP rate limit"
      cidrs       = var.rate_limit_exempt_cidrs
    }
  }

  ip_set_versions = merge([
    for set, cfg in local.ip_sets : {
      "${set}-v4" = { description = cfg.description, version = "IPV4", cidrs = [for c in cfg.cidrs : c if !strcontains(c, ":")] }
      "${set}-v6" = { description = cfg.description, version = "IPV6", cidrs = [for c in cfg.cidrs : c if strcontains(c, ":")] }
    }
  ]...)
}

resource "aws_wafv2_ip_set" "this" {
  for_each = local.ip_set_versions

  name               = "${var.name}-${each.key}"
  description        = each.value.description
  scope              = "CLOUDFRONT"
  ip_address_version = each.value.version
  addresses          = each.value.cidrs
}

locals {
  # Managed rule groups in priority order. CommonRuleSet's body size limit
  # (8 KB) would block media uploads in wp-admin, so it's set to count.
  managed_rule_groups = [
    { name = "AWSManagedRulesAmazonIpReputationList", count_rules = [] },
    { name = "AWSManagedRulesCommonRuleSet", count_rules = ["SizeRestrictions_BODY"] },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", count_rules = [] },
    { name = "AWSManagedRulesSQLiRuleSet", count_rules = [] },
    { name = "AWSManagedRulesPHPRuleSet", count_rules = [] },
    { name = "AWSManagedRulesWordPressRuleSet", count_rules = [] },
  ]
}

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.name}-edge"
  description = "Edge protection for the ${var.name} CMS"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 1. Admin surfaces only from allow-listed networks.
  rule {
    name     = "admin-lockdown"
    priority = 0

    action {
      block {}
    }

    statement {
      and_statement {
        statement {
          or_statement {
            statement {
              byte_match_statement {
                search_string         = "/wp-admin"
                positional_constraint = "STARTS_WITH"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/wp-login.php"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
        # admin-ajax.php is called by public-facing themes and plugins.
        statement {
          not_statement {
            statement {
              byte_match_statement {
                search_string         = "/wp-admin/admin-ajax.php"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
        statement {
          not_statement {
            statement {
              or_statement {
                statement {
                  ip_set_reference_statement {
                    arn = aws_wafv2_ip_set.this["admin-v4"].arn
                  }
                }
                statement {
                  ip_set_reference_statement {
                    arn = aws_wafv2_ip_set.this["admin-v6"].arn
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-admin-lockdown"
      sampled_requests_enabled   = true
    }
  }

  # 2. XML-RPC is a brute-force and amplification vector nobody here needs.
  rule {
    name     = "block-xmlrpc"
    priority = 1

    action {
      block {}
    }

    statement {
      byte_match_statement {
        search_string         = "/xmlrpc.php"
        positional_constraint = "EXACTLY"
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-block-xmlrpc"
      sampled_requests_enabled   = true
    }
  }

  # 3. Per-IP rate limit. A real surge is many IPs each making a few
  #    requests; one IP making thousands is a bot.
  rule {
    name     = "per-ip-rate-limit"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit_per_5min
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"

        scope_down_statement {
          not_statement {
            statement {
              or_statement {
                statement {
                  ip_set_reference_statement {
                    arn = aws_wafv2_ip_set.this["rate-exempt-v4"].arn
                  }
                }
                statement {
                  ip_set_reference_statement {
                    arn = aws_wafv2_ip_set.this["rate-exempt-v6"].arn
                  }
                }
                # A distributed load-test fleet has many changing IPs; it
                # identifies itself with a shared token instead.
                dynamic "statement" {
                  for_each = nonsensitive(var.rate_limit_exempt_token == "") ? [] : [1]
                  content {
                    byte_match_statement {
                      search_string         = var.rate_limit_exempt_token
                      positional_constraint = "EXACTLY"
                      field_to_match {
                        single_header {
                          name = "x-loadtest-token"
                        }
                      }
                      text_transformation {
                        priority = 0
                        type     = "NONE"
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups
    content {
      name     = rule.value.name
      priority = 10 + rule.key

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name

          dynamic "rule_action_override" {
            for_each = rule.value.count_rules
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-${rule.value.name}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-edge"
    sampled_requests_enabled   = true
  }
}
