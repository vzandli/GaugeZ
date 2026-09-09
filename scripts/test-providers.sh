#!/bin/zsh
set -eu
cd "${0:A:h:h}"
build_dir=$(mktemp -d /tmp/gaugez-provider-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$build_dir/module-cache" \
  GaugeZ/Model/UsageModels.swift GaugeZ/Model/ProviderRetryPolicy.swift GaugeZ/Model/ThresholdNotifier.swift \
  GaugeZ/Credentials/ClaudeProfile.swift GaugeZ/Credentials/ClaudeKeychain.swift \
  GaugeZ/Credentials/ProviderSecretCache.swift GaugeZ/Credentials/AntigravityCredentials.swift \
  GaugeZ/Credentials/GLMCredentials.swift \
  GaugeZ/Providers/ClaudeUsageProvider.swift GaugeZ/Providers/GLMUsageProvider.swift \
  GaugeZ/Providers/GrokUsageProvider.swift GaugeZ/Providers/CursorUsageProvider.swift \
  GaugeZ/Providers/CodexUsageProvider.swift GaugeZ/Providers/OpenCodeUsageProvider.swift \
  GaugeZ/Providers/GitHubCopilotProvider.swift GaugeZ/Providers/AntigravityUsageProvider.swift \
  GaugeZ/Sessions/ActivityReader.swift GaugeZ/Sessions/AntigravityActivity.swift \
  GaugeZ/Sessions/SessionCompletionWatcher.swift GaugeZ/Sessions/ClaudeTranscript.swift \
  GaugeZ/Credentials/ClaudeTokenRenewal.swift GaugeZ/Model/RefreshDeadline.swift \
  GaugeZ/App/ReleaseNotes.swift GaugeZ/App/AppLanguage.swift \
  Tests/ProviderRegressionTests.swift -o "$build_dir/provider-tests"
"$build_dir/provider-tests"
"$build_dir/provider-tests"
