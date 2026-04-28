#!/bin/sh
set -eu

cd "$(dirname "$0")"

for f in \
  "src/utils/auth.ts" \
  "src/utils/model/model.ts" \
  "src/utils/model/modelOptions.ts" \
  "src/utils/planModeV2.ts" \
  "src/utils/permissions/permissionSetup.ts" \
  "src/services/api/referral.ts" \
  "src/tools/AgentTool/prompt.ts" \
  "src/utils/attachments.ts"
do
  if [ ! -f "$f" ]; then
    echo "Missing file: $f" >&2
    exit 1
  fi
done

if grep -q "export function hasMaxFeatureParity" "src/utils/auth.ts" &&
   grep -q "if (subscriptionType === 'pro') {" "src/utils/planModeV2.ts"; then
  echo "Pro->Max feature patch already appears to be applied."
  exit 0
fi

sed -i.bak '
/^export function isProSubscriber(): boolean {$/,/^}$/c\
export function isProSubscriber(): boolean {\
  return getSubscriptionType() === '\''pro'\''\
}\
\
/**\
 * Local feature parity helper: treat Pro like Max for client-side capability\
 * gates without rewriting billing or server-reported quota state.\
 */\
export function hasMaxFeatureParity(): boolean {\
  const subscriptionType = getSubscriptionType()\
  return subscriptionType === '\''max'\'' || subscriptionType === '\''pro'\''\
}
' src/utils/auth.ts

sed -i.bak '
s/^  getSubscriptionType,$/  hasMaxFeatureParity,\
  getSubscriptionType,/
/^  isMaxSubscriber,$/d
/^  isProSubscriber,$/d
s/^  \/\/ Max users get Opus as default$/  \/\/ Max-like users get Opus as default/
s/^  if (isMaxSubscriber()) {$/  if (hasMaxFeatureParity()) {/
s/^  if (isMaxSubscriber() || isTeamPremiumSubscriber()) {$/  if (hasMaxFeatureParity() || isTeamPremiumSubscriber()) {/
/^    isProSubscriber() ||$/d
s/^  \/\/ isProSubscriber() returns false for such users and the merge leaks$/  \/\/ the merge can leak/
' src/utils/model/model.ts

sed -i.bak '
s/^  isClaudeAISubscriber,$/  hasMaxFeatureParity,\
  isClaudeAISubscriber,/
/^  isMaxSubscriber,$/d
s/^    if (isMaxSubscriber() || isTeamPremiumSubscriber()) {$/    if (hasMaxFeatureParity() || isTeamPremiumSubscriber()) {/
s/^      \/\/ Max and Team Premium users: Opus is default, show Sonnet as alternative$/      \/\/ Max-like and Team Premium users: Opus is default, show Sonnet as alternative/
' src/utils/model/modelOptions.ts

sed -i.bak '
/^import { getFeatureValue_CACHED_MAY_BE_STALE } from '\''\.\.\/services\/analytics\/growthbook\.js'\''$/,/^import { isEnvDefinedFalsy, isEnvTruthy } from '\''\.\/envUtils\.js'\''$/c\
import { getFeatureValue_CACHED_MAY_BE_STALE } from '\''../services/analytics/growthbook.js'\''\
import {\
  getRateLimitTier,\
  getSubscriptionType,\
  hasMaxFeatureParity,\
} from '\''./auth.js'\''\
import { isEnvDefinedFalsy, isEnvTruthy } from '\''./envUtils.js'\''
/^  const subscriptionType = getSubscriptionType()$/,/^  ) {$/c\
  const subscriptionType = getSubscriptionType()\
  const rateLimitTier = getRateLimitTier()\
\
  if (subscriptionType === '\''pro'\'') {\
    return 3\
  }\
\
  if (\
    subscriptionType === '\''max'\'' &&\
    rateLimitTier === '\''default_claude_max_20x'\''\
  ) {
/^  if (subscriptionType === '\''enterprise'\'' || subscriptionType === '\''team'\'') {$/c\
  if (\
    subscriptionType === '\''enterprise'\'' ||\
    subscriptionType === '\''team'\'' ||\
    hasMaxFeatureParity()\
  ) {
' src/utils/planModeV2.ts

sed -i.bak '
/^import { getMainLoopModel } from '\''\.\.\/model\/model\.js'\''$/a\
import { isProSubscriber } from '\''../auth.js'\''
/^  const autoModeConfig = await getDynamicConfig_BLOCKS_ON_INIT<{$/,/^  const enabledState = parseAutoModeEnabledState(autoModeConfig?.enabled)$/c\
  const autoModeConfig = await getDynamicConfig_BLOCKS_ON_INIT<{\
    enabled?: AutoModeEnabledState\
    disableFastMode?: boolean\
  }>('''\'tengu_auto_mode_config\'''', {})\
  const fetchedEnabledState = parseAutoModeEnabledState(autoModeConfig?.enabled)\
  const enabledState =\
    process.env.USER_TYPE !== '\''ant'\'' &&\
    isProSubscriber() &&\
    fetchedEnabledState === '\''disabled'\''\
      ? '\''enabled'\''\
      : fetchedEnabledState
' src/utils/permissions/permissionSetup.ts

sed -i.bak '
/^import {$/,/^} from '\''\.\.\/\.\.\/utils\/auth\.js'\''$/c\
import {\
  getOauthAccountInfo,\
  hasMaxFeatureParity,\
  isClaudeAISubscriber,\
} from '\''../../utils/auth.js'\''
/^function shouldCheckForPasses(): boolean {$/,/^}$/c\
function shouldCheckForPasses(): boolean {\
  return !!(\
    getOauthAccountInfo()?.organizationUuid &&\
    isClaudeAISubscriber() &&\
    hasMaxFeatureParity()\
  )\
}
' src/services/api/referral.ts

sed -i.bak '
/^import { getSubscriptionType } from '\''\.\.\/\.\.\/utils\/auth\.js'\''$/d
s/^  \/\/ attachment message (conditioned on subscription there). When inline, keep$/  \/\/ attachment message. Keep the inline copy aligned so Pro users see the same/
s/^  \/\/ the existing per-call getSubscriptionType() check\.$/  \/\/ guidance as Max users./
s/^    !listViaAttachment && getSubscriptionType() !== '\''pro'\''$/    !listViaAttachment/
' src/tools/AgentTool/prompt.ts

sed -i.bak '
/^import { getSubscriptionType } from '\''\.\/auth\.js'\''$/d
s/showConcurrencyNote: getSubscriptionType() !== '\''pro'\''/showConcurrencyNote: true/
' src/utils/attachments.ts

rm -f \
  src/utils/auth.ts.bak \
  src/utils/model/model.ts.bak \
  src/utils/model/modelOptions.ts.bak \
  src/utils/planModeV2.ts.bak \
  src/utils/permissions/permissionSetup.ts.bak \
  src/services/api/referral.ts.bak \
  src/tools/AgentTool/prompt.ts.bak \
  src/utils/attachments.ts.bak

echo "Applied Pro->Max feature parity patch with simple sed -i edits."
