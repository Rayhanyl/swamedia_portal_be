import ballerina/email;
import rayha/swamedia_portal_be.config;

# ===== Outbound SMTP =====
#
# Thin wrapper over `ballerina/email`. Lazy-initialized for the same reason as the Postgres/Redis
# clients in db.bal/cache.bal — keeps `bal build`/`bal test` free of a live mail server dependency;
# an empty `config:smtpHost` only fails when a send is actually attempted.

isolated email:SmtpClient? cachedSmtpClient = ();

isolated function smtpClient() returns email:SmtpClient|error {
    lock {
        email:SmtpClient? existing = cachedSmtpClient;
        if existing is email:SmtpClient {
            return existing;
        }
        email:SmtpClient newClient = check new (config:smtpHost, config:smtpUsername, config:smtpPassword,
                port = config:smtpPort, security = smtpSecurityFromConfig());
        cachedSmtpClient = newClient;
        return newClient;
    }
}

isolated function smtpSecurityFromConfig() returns email:Security {
    match config:smtpSecurity {
        "START_TLS_ALWAYS" => {
            return email:START_TLS_ALWAYS;
        }
        "START_TLS_NEVER" => {
            return email:START_TLS_NEVER;
        }
        "SSL" => {
            return email:SSL;
        }
        _ => {
            return email:START_TLS_AUTO;
        }
    }
}

# Sends a single plain-text email via the configured SMTP server.
#
# + to - recipient address
# + fromAddress - sender address (caller resolves this — e.g. from `sys_config.notif_email_pengirim`)
# + subject - email subject
# + body - plain-text email body
# + return - () if accepted by the SMTP server, or an error
public isolated function sendEmail(string to, string fromAddress, string subject, string body) returns error? {
    email:SmtpClient smtp = check smtpClient();
    email:Message message = {
        to: [to],
        'from: fromAddress,
        subject: subject,
        body: body
    };
    check smtp->sendMessage(message);
}
