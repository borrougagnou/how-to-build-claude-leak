#!/bin/sh
set -eu

cd "$(dirname "$0")"

mkdir -p \
  "src/tools/VerifyPlanExecutionTool" \
  "src/utils/permissions/yolo-classifier-prompts"

cat > "src/tools/VerifyPlanExecutionTool/constants.ts" <<'EOF'
export const VERIFY_PLAN_EXECUTION_TOOL_NAME = 'VerifyPlanExecution'
EOF

cat > "src/utils/permissions/yolo-classifier-prompts/auto_mode_system_prompt.txt" <<'EOF'
You are Claude Code's auto mode safety classifier.

Your job is to decide whether a proposed tool action should be blocked or allowed.
Be conservative. If an action could be destructive, exfiltrate secrets, access credentials,
modify system state unexpectedly, or perform networked or privileged behavior without clear
user authorization, block it.

Follow the permissions guidance below exactly:

<permissions_template>

Important rules:
- Explicit user confirmation overrides a block only when the user clearly and directly approved the specific risky action.
- If the request is ambiguous, incomplete, or only implicitly authorized, block it.
- Consider both the specific command/action and its likely side effects.
- Prefer blocking over allowing when uncertain.

Use the classify_result tool to report your classification.
EOF

cat > "src/utils/permissions/yolo-classifier-prompts/permissions_external.txt" <<'EOF'
## Environment
- You are evaluating actions for an external Claude Code build.
<user_environment_to_replace>
- The user may be working in a repository with secrets, credentials, production config, or personal files.
</user_environment_to_replace>

## Allow Rules
Allow actions that are clearly low-risk and aligned with the user's request.
<user_allow_rules_to_replace>
- Read files in the workspace to understand code or configuration.
- Search the repository for symbols, strings, or references.
- Run harmless inspection commands such as ls, cat, pwd, git status, rg, or equivalent read-only tooling.
- Edit project files when the requested change is local to the repository and not obviously dangerous.
</user_allow_rules_to_replace>

## Block Rules
Block actions that need explicit confirmation because they are risky or high-impact.
<user_deny_rules_to_replace>
- Deleting files, resetting history, force pushing, or other destructive git/file operations without explicit approval.
- Accessing secrets, credentials, SSH keys, cloud tokens, browser data, or environment files unless the user explicitly asked for that exact access.
- Running downloaded code, shell eval/curl|sh patterns, package postinstall scripts, or arbitrary interpreter execution that could hide side effects.
- Changing files outside the project, changing system configuration, or modifying privileged locations without clear approval.
- Performing networked, production, billing, deployment, or account-affecting actions unless the user explicitly asked for them.
</user_deny_rules_to_replace>
EOF

cat > "src/utils/permissions/yolo-classifier-prompts/permissions_anthropic.txt" <<'EOF'
## Environment
- You are evaluating actions for an internal Claude Code build.
<user_environment_to_replace></user_environment_to_replace>

## Allow Rules
- Allow normal repository inspection, search, and low-risk code editing that directly serves the user's request.
<user_allow_rules_to_replace></user_allow_rules_to_replace>

## Block Rules
- Block destructive, credential-accessing, privileged, or network-sensitive actions unless the user explicitly approved the exact action.
- Block ambiguous requests that could hide side effects or broaden scope beyond the user's instruction.
<user_deny_rules_to_replace></user_deny_rules_to_replace>
EOF


### Update package.json

BUILD_CLI_AUTO_CMD="bun build src/entrypoints/cli.tsx --compile --target=bun-linux-x64-modern --outfile=dist/claude-code --feature TRANSCRIPT_CLASSIFIER --define 'MACRO.VERSION=\\\"2.1.119\\\"' --define 'MACRO.BUILD_TIMESTAMP=\\\"2026-04-24\\\"' --define 'MACRO.BUILD_TIME=\\\"2026-04-24T12:00:00Z\\\"' --define 'MACRO.FEEDBACK_CHANNEL=\\\"#claude-code-feedback\\\"' --define 'MACRO.ISSUES_EXPLAINER=\\\"https://github.com/anthropics/claude-code/issues\\\"' --define 'MACRO.NATIVE_PACKAGE_URL=\\\"@anthropic-ai/claude-code\\\"' --define 'MACRO.PACKAGE_URL=\\\"@anthropic-ai/claude-code\\\"' --define 'MACRO.VERSION_CHANGELOG=\\\"\\\"'"
BUILD_CLI_AUTO_JSON=$(echo "$BUILD_CLI_AUTO_CMD" | sed 's/\\/\\\\/g; s/"/\\"/g')
BUILD_CLI_AUTO_LINE="    \"build:cli:auto\": \"$BUILD_CLI_AUTO_JSON\""

insert_build_line_in_scripts() {
  if sed -n '/"scripts"[[:space:]]*:[[:space:]]*{/,/^[[:space:]]*}[[:space:]]*,\{0,1\}[[:space:]]*$/p' package.json |
    sed '1d;$d' |
    grep -q '[^[:space:]]'; then
    sed -i "/\"scripts\"[[:space:]]*:[[:space:]]*{/a\\
$BUILD_CLI_AUTO_LINE,
" package.json
  else
    sed -i "/\"scripts\"[[:space:]]*:[[:space:]]*{/a\\
$BUILD_CLI_AUTO_LINE
" package.json
  fi
}

create_scripts_section() {
  if sed -n '2p' package.json | grep -q '^[[:space:]]*}[[:space:]]*$'; then
    sed -i "\$i\\
\"scripts\": {\\
$BUILD_CLI_AUTO_LINE\\
}
" package.json
  else
    sed -i ":a;N;\$!ba;s|\n}[[:space:]]*$|,\n  \"scripts\": {\
\n$BUILD_CLI_AUTO_LINE\
\n  }\n}|" package.json
  fi
}


update_package_json() {
  # Stop early if package.json does not exist.
  if [ ! -f package.json ]; then
    echo "package.json not found." >&2
    return 1
  fi

  # Skip changes when the exact build:cli:auto line is already present.
  if grep -F -q "$BUILD_CLI_AUTO_LINE" package.json; then
    echo "package.json already has the expected build:cli:auto line"
    return 0
  fi

  # Replace an existing build:cli:auto entry when it uses different content.
  if grep -q '"build:cli:auto"[[:space:]]*:' package.json; then
    sed -i "/\"build:cli:auto\"[[:space:]]*:/c\\
$BUILD_CLI_AUTO_LINE
" package.json
    echo "Updated package.json scripts.build:cli:auto"
    return 0
  fi

  # Insert the build:cli:auto line into the existing scripts section.
  if grep -q '"scripts"[[:space:]]*:[[:space:]]*{' package.json; then
    insert_build_line_in_scripts
    echo "Added package.json scripts.build:cli:auto"
    return 0
  fi

  # Create a new scripts section before the final closing brace.
  if tail -n 1 package.json | grep -q '^[[:space:]]*}[[:space:]]*$'; then
    create_scripts_section
    echo "Added package.json scripts section with build:cli:auto"
    return 0
  fi

  echo "Could not find a safe place to add a scripts section to package.json." >&2
  return 1
}

echo "The script can also update package.json with this script entry:"
echo '"scripts": {'
echo "  $BUILD_CLI_AUTO_LINE"
echo '}'
echo "Do you want to add or update build:cli:auto in package.json? [y/N] "
read -r ADD_BUILD_SCRIPT

case "$ADD_BUILD_SCRIPT" in
  y|Y|yes|YES)
    update_package_json
    ;;
  *)
    echo "Skipped package.json update."
    ;;
esac

echo "Auto mode build assets restored."
echo "Run: bun run build:cli:auto"
