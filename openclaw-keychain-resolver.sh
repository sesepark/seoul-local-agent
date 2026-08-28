#!/bin/zsh
# Resolves only the two Slack credentials from this Mac's login Keychain.
# No secret values are stored in this file.

bot_token=$(/usr/bin/security find-generic-password -a "openclaw-local" -s "com.openclaw.slack.bot-token" -w 2>/dev/null) || exit 1
app_token=$(/usr/bin/security find-generic-password -a "openclaw-local" -s "com.openclaw.slack.app-token" -w 2>/dev/null) || exit 1

print -r -- "{\"protocolVersion\":1,\"values\":{\"slack.bot\":\"${bot_token}\",\"slack.app\":\"${app_token}\"}}"
