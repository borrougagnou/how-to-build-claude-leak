#!/bin/sh
set -eu

cd "$(dirname "$0")"

if ! command -v patch >/dev/null 2>&1; then
  echo "patch command not found." >&2
  exit 1
fi

apply_patch_if_needed() {
  file_path="$1"
  check_pattern="$2"
  patch_name="$3"

  if grep -F -q "$check_pattern" "$file_path"; then
    echo "Warning: already patched: $file_path ($patch_name)"
    return 0
  fi

  patch -N --batch -p0
}

apply_patch_if_needed \
  "src/utils/auth.ts" \
  "export function hasMaxFeatureParity(): boolean" \
  "max-feature-parity helper" <<'EOF'
--- src/utils/auth.ts
+++ src/utils/auth.ts
@@ -1699,6 +1699,11 @@
   return getSubscriptionType() === 'pro'
 }
 
+export function hasMaxFeatureParity(): boolean {
+  const subscriptionType = getSubscriptionType()
+  return subscriptionType === 'max' || subscriptionType === 'pro'
+}
+
 export function getRateLimitTier(): string | null {
   if (!isAnthropicAuthEnabled()) {
     return null
EOF

apply_patch_if_needed \
  "src/utils/model/model.ts" \
  "hasMaxFeatureParity() || isTeamPremiumSubscriber()" \
  "model defaults and opus 1m parity" <<'EOF'
--- src/utils/model/model.ts
+++ src/utils/model/model.ts
@@ -8,9 +8,8 @@
 import { getMainLoopModelOverride } from '../../bootstrap/state.js'
 import {
   getSubscriptionType,
+  hasMaxFeatureParity,
   isClaudeAISubscriber,
-  isMaxSubscriber,
-  isProSubscriber,
   isTeamPremiumSubscriber,
 } from '../auth.js'
 import {
@@ -184,8 +183,8 @@
     )
   }
 
-  // Max users get Opus as default
-  if (isMaxSubscriber()) {
+  // Max-like users get Opus as default
+  if (hasMaxFeatureParity()) {
     return getDefaultOpusModel() + (isOpus1mMergeEnabled() ? '[1m]' : '')
   }
 
@@ -286,7 +285,7 @@
 export function getClaudeAiUserDefaultModelDescription(
   fastMode = false,
 ): string {
-  if (isMaxSubscriber() || isTeamPremiumSubscriber()) {
+  if (hasMaxFeatureParity() || isTeamPremiumSubscriber()) {
     if (isOpus1mMergeEnabled()) {
       return `Opus 4.6 with 1M context · Most capable for complex work${fastMode ? getOpus46PricingSuffix(true) : ''}`
     }
@@ -314,7 +313,6 @@
 export function isOpus1mMergeEnabled(): boolean {
   if (
     is1mContextDisabled() ||
-    isProSubscriber() ||
     getAPIProvider() !== 'firstParty'
   ) {
     return false
@@ -322,7 +320,7 @@
   // Fail closed when a subscriber's subscription type is unknown. The VS Code
   // config-loading subprocess can have OAuth tokens with valid scopes but no
   // subscriptionType field (stale or partial refresh). Without this guard,
-  // isProSubscriber() returns false for such users and the merge leaks
+  // the merge leaks
   // opus[1m] into the model dropdown — the API then rejects it with a
   // misleading "rate limit reached" error.
  if (isClaudeAISubscriber() && getSubscriptionType() === null) {
EOF

apply_patch_if_needed \
  "src/utils/model/check1mAccess.ts" \
  "if (hasMaxFeatureParity()) {" \
  "1m access parity" <<'EOF'
--- src/utils/model/check1mAccess.ts
+++ src/utils/model/check1mAccess.ts
@@ -1,5 +1,5 @@
 import type { OverageDisabledReason } from 'src/services/claudeAiLimits.js'
-import { isClaudeAISubscriber } from '../auth.js'
+import { hasMaxFeatureParity, isClaudeAISubscriber } from '../auth.js'
 import { getGlobalConfig } from '../config.js'
 import { is1mContextDisabled } from '../context.js'
 
@@ -46,6 +46,10 @@
   if (is1mContextDisabled()) {
     return false
   }
+
+  if (hasMaxFeatureParity()) {
+    return true
+  }
 
   if (isClaudeAISubscriber()) {
     // Subscribers have access if extra usage is enabled for their account
@@ -60,6 +64,10 @@
   if (is1mContextDisabled()) {
     return false
   }
+
+  if (hasMaxFeatureParity()) {
+    return true
+  }
 
   if (isClaudeAISubscriber()) {
     // Subscribers have access if extra usage is enabled for their account
EOF

apply_patch_if_needed \
  "src/utils/model/modelOptions.ts" \
  "premiumOptions.push(getOpusPlanOption())" \
  "model picker parity" <<'EOF'
--- src/utils/model/modelOptions.ts
+++ src/utils/model/modelOptions.ts
@@ -1,8 +1,8 @@
 // biome-ignore-all assist/source/organizeImports: ANT-ONLY import markers must not be reordered
 import { getInitialMainLoopModel } from '../../bootstrap/state.js'
 import {
+  hasMaxFeatureParity,
   isClaudeAISubscriber,
-  isMaxSubscriber,
   isTeamPremiumSubscriber,
 } from '../auth.js'
 import { getModelStrings } from './modelStrings.js'
@@ -288,18 +288,14 @@
   }
 
   if (isClaudeAISubscriber()) {
-    if (isMaxSubscriber() || isTeamPremiumSubscriber()) {
-      // Max and Team Premium users: Opus is default, show Sonnet as alternative
+    if (hasMaxFeatureParity() || isTeamPremiumSubscriber()) {
+      // Max-like and Team Premium users: show both standard and explicit 1M variants.
       const premiumOptions = [getDefaultOptionForUser(fastMode)]
-      if (!isOpus1mMergeEnabled() && checkOpus1mAccess()) {
-        premiumOptions.push(getMaxOpus46_1MOption(fastMode))
-      }
-
+      premiumOptions.push(getMaxOpusOption(fastMode))
+      premiumOptions.push(getMaxOpus46_1MOption(fastMode))
       premiumOptions.push(MaxSonnet46Option)
-      if (checkSonnet1mAccess()) {
-        premiumOptions.push(getMaxSonnet46_1MOption())
-      }
-
+      premiumOptions.push(getMaxSonnet46_1MOption())
+      premiumOptions.push(getOpusPlanOption())
       premiumOptions.push(MaxHaiku45Option)
       return premiumOptions
     }
EOF

apply_patch_if_needed \
  "src/commands/model/model.tsx" \
  "Apply the same 1M availability guards as \`/model <alias>\`." \
  "interactive model picker 1m guards" <<'EOF'
--- src/commands/model/model.tsx
+++ src/commands/model/model.tsx
@@ -50,6 +50,19 @@
         from_model: mainLoopModel as AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS,
         to_model: model as AnalyticsMetadata_I_VERIFIED_THIS_IS_NOT_CODE_OR_FILEPATHS
       });
+      // Apply the same 1M availability guards as `/model <alias>`.
+      if (model && isOpus1mUnavailable(model)) {
+        onDone(`Opus 4.6 with 1M context is not available for your account. Learn more: https://code.claude.com/docs/en/model-config#extended-context-with-1m`, {
+          display: "system"
+        });
+        return;
+      }
+      if (model && isSonnet1mUnavailable(model)) {
+        onDone(`Sonnet 4.6 with 1M context is not available for your account. Learn more: https://code.claude.com/docs/en/model-config#extended-context-with-1m`, {
+          display: "system"
+        });
+        return;
+      }
       setAppState(prev => ({
         ...prev,
         mainLoopModel: model,
EOF

apply_patch_if_needed \
  "src/utils/planModeV2.ts" \
  "if (subscriptionType === 'pro') {" \
  "plan parallelism parity" <<'EOF'
--- src/utils/planModeV2.ts
+++ src/utils/planModeV2.ts
@@ -1,5 +1,5 @@
 import { getFeatureValue_CACHED_MAY_BE_STALE } from '../services/analytics/growthbook.js'
-import { getRateLimitTier, getSubscriptionType } from './auth.js'
+import { getRateLimitTier, getSubscriptionType, hasMaxFeatureParity } from './auth.js'
 import { isEnvDefinedFalsy, isEnvTruthy } from './envUtils.js'
 
 export function getPlanModeV2AgentCount(): number {
@@ -14,6 +14,10 @@
   const subscriptionType = getSubscriptionType()
   const rateLimitTier = getRateLimitTier()
 
+  if (subscriptionType === 'pro') {
+    return 3
+  }
+
   if (
     subscriptionType === 'max' &&
     rateLimitTier === 'default_claude_max_20x'
@@ -21,7 +25,11 @@
     return 3
   }
 
-  if (subscriptionType === 'enterprise' || subscriptionType === 'team') {
+  if (
+    subscriptionType === 'enterprise' ||
+    subscriptionType === 'team' ||
+    hasMaxFeatureParity()
+  ) {
     return 3
   }
EOF

apply_patch_if_needed \
  "src/utils/permissions/getNextPermissionMode.ts" \
  "case 'auto':" \
  "shift-tab auto mode parity" <<'EOF'
--- src/utils/permissions/getNextPermissionMode.ts
+++ src/utils/permissions/getNextPermissionMode.ts
@@ -50,9 +50,18 @@
       return 'acceptEdits'
 
     case 'acceptEdits':
+      if (process.env.USER_TYPE !== 'ant' && canCycleToAuto(toolPermissionContext)) {
+        return 'auto'
+      }
       return 'plan'
 
     case 'plan':
+      if (process.env.USER_TYPE !== 'ant') {
+        if (toolPermissionContext.isBypassPermissionsModeAvailable) {
+          return 'bypassPermissions'
+        }
+        return 'default'
+      }
       if (toolPermissionContext.isBypassPermissionsModeAvailable) {
         return 'bypassPermissions'
       }
@@ -62,6 +71,9 @@
       return 'default'
 
     case 'bypassPermissions':
+      if (process.env.USER_TYPE !== 'ant') {
+        return 'default'
+      }
       if (canCycleToAuto(toolPermissionContext)) {
         return 'auto'
       }
@@ -71,6 +83,12 @@
       // Not exposed in UI cycle yet, but return default if somehow reached
       return 'default'
 
+    case 'auto':
+      if (process.env.USER_TYPE !== 'ant') {
+        return 'plan'
+      }
+      return 'default'
+
 
     default:
       // Covers auto (when TRANSCRIPT_CLASSIFIER is enabled) and any future modes — always fall back to default
EOF

apply_patch_if_needed \
  "src/utils/permissions/permissionSetup.ts" \
  "const fetchedEnabledState = parseAutoModeEnabledState(autoModeConfig?.enabled)" \
  "auto mode gate parity" <<'EOF'
--- src/utils/permissions/permissionSetup.ts
+++ src/utils/permissions/permissionSetup.ts
@@ -61,6 +61,7 @@
 import { logForDebugging } from '../debug.js'
 import { gracefulShutdown } from '../gracefulShutdown.js'
 import { getMainLoopModel } from '../model/model.js'
+import { isProSubscriber } from '../auth.js'
 import {
   CROSS_PLATFORM_CODE_EXEC,
   DANGEROUS_BASH_PATTERNS,
@@ -1092,7 +1093,13 @@
     enabled?: AutoModeEnabledState
     disableFastMode?: boolean
   }>('tengu_auto_mode_config', {})
-  const enabledState = parseAutoModeEnabledState(autoModeConfig?.enabled)
+  const fetchedEnabledState = parseAutoModeEnabledState(autoModeConfig?.enabled)
+  const enabledState =
+    process.env.USER_TYPE !== 'ant' &&
+    isProSubscriber() &&
+    fetchedEnabledState === 'disabled'
+      ? 'enabled'
+      : fetchedEnabledState
   const disabledBySettings = isAutoModeDisabledBySettings()
   // Treat settings-disable the same as GrowthBook 'disabled' for circuit-breaker
   // semantics — blocks SDK/explicit re-entry via isAutoModeGateEnabled().
EOF

apply_patch_if_needed \
  "src/services/api/referral.ts" \
  "hasMaxFeatureParity()" \
  "referral parity" <<'EOF'
--- src/services/api/referral.ts
+++ src/services/api/referral.ts
@@ -2,7 +2,7 @@
 import { getOauthConfig } from '../../constants/oauth.js'
 import {
   getOauthAccountInfo,
-  getSubscriptionType,
+  hasMaxFeatureParity,
   isClaudeAISubscriber,
 } from '../../utils/auth.js'
 import { getGlobalConfig, saveGlobalConfig } from '../../utils/config.js'
@@ -72,7 +72,7 @@
   return !!(
     getOauthAccountInfo()?.organizationUuid &&
     isClaudeAISubscriber() &&
-    getSubscriptionType() === 'max'
+    hasMaxFeatureParity()
   )
 }
EOF

apply_patch_if_needed \
  "src/tools/AgentTool/prompt.ts" \
  "guidance as Max users." \
  "agent prompt concurrency note parity" <<'EOF'
--- src/tools/AgentTool/prompt.ts
+++ src/tools/AgentTool/prompt.ts
@@ -1,5 +1,4 @@
 import { getFeatureValue_CACHED_MAY_BE_STALE } from '../../services/analytics/growthbook.js'
-import { getSubscriptionType } from '../../utils/auth.js'
 import { hasEmbeddedSearchTools } from '../../utils/embeddedTools.js'
 import { isEnvDefinedFalsy, isEnvTruthy } from '../../utils/envUtils.js'
 import { isTeammate } from '../../utils/teammate.js'
@@ -240,10 +239,10 @@
 `
 
   // When listing via attachment, the "launch multiple agents" note is in the
-  // attachment message (conditioned on subscription there). When inline, keep
-  // the existing per-call getSubscriptionType() check.
+  // attachment message. Keep the inline copy aligned so Pro users see the same
+  // guidance as Max users.
   const concurrencyNote =
-    !listViaAttachment && getSubscriptionType() !== 'pro'
+    !listViaAttachment
       ? `
 - Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses`
       : ''
EOF

apply_patch_if_needed \
  "src/utils/attachments.ts" \
  "showConcurrencyNote: true," \
  "attachment concurrency note parity" <<'EOF'
--- src/utils/attachments.ts
+++ src/utils/attachments.ts
@@ -127,7 +127,6 @@
   shouldInjectAgentListInMessages,
 } from '../tools/AgentTool/prompt.js'
 import { filterDeniedAgents } from './permissions/permissions.js'
-import { getSubscriptionType } from './auth.js'
 import { mcpInfoFromString } from '../services/mcp/mcpStringUtils.js'
 import {
   matchingRuleForInput,
@@ -695,7 +694,7 @@
       removedTypes: string[]
       /** True when this is the first announcement in the conversation */
       isInitial: boolean
-      /** Whether to include the "launch multiple agents concurrently" note (non-pro subscriptions) */
+      /** Whether to include the "launch multiple agents concurrently" note */
       showConcurrencyNote: boolean
     }
   | {
@@ -1550,7 +1549,7 @@
       addedLines: added.map(formatAgentLine),
       removedTypes: removed,
       isInitial: announced.size === 0,
-      showConcurrencyNote: getSubscriptionType() !== 'pro',
+      showConcurrencyNote: true,
     },
   ]
 }
EOF

echo "Pro/Max client-side parity patch finished."
