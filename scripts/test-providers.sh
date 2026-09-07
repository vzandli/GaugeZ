#!/bin/zsh
set -eu
cd "${0:A:h:h}"
build_dir=$(mktemp -d /tmp/gaugez-provider-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$build_dir/module-cache" \
  GaugeZ/UsageModels.swift GaugeZ/ClaudeProfile.swift GaugeZ/ClaudeKeychain.swift \
  GaugeZ/ClaudeUsageProvider.swift GaugeZ/ProviderRetryPolicy.swift \
  GaugeZ/GLMCredentials.swift GaugeZ/GLMUsageProvider.swift GaugeZ/GrokUsageProvider.swift \
  GaugeZ/CursorUsageProvider.swift GaugeZ/CodexUsageProvider.swift GaugeZ/OpenCodeUsageProvider.swift \
  GaugeZ/ReleaseNotes.swift GaugeZ/ActivityReader.swift \
  Tests/ProviderRegressionTests.swift -o "$build_dir/provider-tests"
"$build_dir/provider-tests"
