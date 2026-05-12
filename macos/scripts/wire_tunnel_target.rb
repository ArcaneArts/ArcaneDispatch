#!/usr/bin/env ruby
# wire_tunnel_target.rb
#
# Idempotent script that wires the ArcaneDispatchTunnel Network Extension as a
# real PBXNativeTarget inside `macos/Runner.xcodeproj`. Re-runnable: if the
# target already exists the script updates its compile/embed file lists and
# returns without duplicating anything.
#
# Without this wiring, `TunnelTransport` (Dart) → `TunnelManager` (Swift) can
# call `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:
# "art.arcane.ArcaneDispatch.tunnel")` but the OS replies "no such extension
# installed" because the .appex was never built or embedded. This script makes
# Tunnel mode actually executable.
#
# Run from the `macos/` directory:
#
#   ruby scripts/wire_tunnel_target.rb
#
# Requires the `xcodeproj` gem (ships with CocoaPods on macOS).

require 'xcodeproj'
require 'pathname'

PROJECT_PATH       = 'Runner.xcodeproj'
TUNNEL_DIR         = 'ArcaneDispatchTunnel'
TUNNEL_TARGET_NAME = 'ArcaneDispatchTunnel'
TUNNEL_BUNDLE_ID   = 'art.arcane.ArcaneDispatch.tunnel'
TUNNEL_INFO_PLIST  = "#{TUNNEL_DIR}/Info.plist"
TUNNEL_ENTITLEMENTS = "#{TUNNEL_DIR}/#{TUNNEL_TARGET_NAME}.entitlements"
RUNNER_TARGET_NAME = 'Runner'
DEVELOPMENT_TEAM   = 'RK2CYG6XRV'

abort "Run me from the macos/ directory (project.pbxproj not found at #{PROJECT_PATH})" \
  unless File.directory?(PROJECT_PATH)

project = Xcodeproj::Project.open(PROJECT_PATH)

runner_target = project.targets.find { |t| t.name == RUNNER_TARGET_NAME }
abort "Could not find Runner target" if runner_target.nil?

# ---------------------------------------------------------------------------
# Discover the Swift sources that need to compile into the extension.
# ---------------------------------------------------------------------------
swift_files = Dir.glob("#{TUNNEL_DIR}/**/*.swift").sort
abort "No Swift sources found under #{TUNNEL_DIR}/" if swift_files.empty?

puts "Discovered #{swift_files.length} Swift sources under #{TUNNEL_DIR}/:"
swift_files.each { |f| puts "  - #{f}" }

# ---------------------------------------------------------------------------
# Find-or-create the ArcaneDispatchTunnel group in the project tree.
# ---------------------------------------------------------------------------
tunnel_group = project.main_group[TUNNEL_DIR] ||
               project.main_group.new_group(TUNNEL_DIR, TUNNEL_DIR)

# Recursively prune groups whose paths no longer exist on disk. Keeps the
# project tidy when files get reorganized between runs.
def ensure_group(parent_group, segments, base_path)
  return parent_group if segments.empty?
  head = segments.first
  rest = segments.drop(1)
  child = parent_group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == head }
  child ||= parent_group.new_group(head, head)
  ensure_group(child, rest, File.join(base_path, head))
end

# Replace the ArcaneDispatchTunnel group's file references with exactly the
# Swift sources we discovered. We do this by clearing the group's children
# first, then re-adding — keeps the script idempotent without complex diffing.
tunnel_group.children.dup.each do |child|
  # Don't blow away nested groups; we'll rebuild file refs only.
  next if child.is_a?(Xcodeproj::Project::Object::PBXGroup)
  tunnel_group.remove_reference(child)
end
# Also wipe any stale source-file build files attached to the old extension
# target before we rebuild it.
old_target = project.targets.find { |t| t.name == TUNNEL_TARGET_NAME }
if old_target
  old_target.source_build_phase.files.dup.each(&:remove_from_project)
end

swift_refs = swift_files.map do |path|
  # Build the nested group chain so Bonded/, Crypto/, Engine/, QoS/ etc.
  # appear as real folders inside the navigator.
  rel = Pathname.new(path).relative_path_from(Pathname.new(TUNNEL_DIR))
  segments = rel.dirname.to_s == '.' ? [] : rel.dirname.to_s.split(File::SEPARATOR)
  group = ensure_group(tunnel_group, segments, TUNNEL_DIR)
  ref = group.files.find { |f| f.path == rel.basename.to_s }
  ref ||= group.new_reference(rel.basename.to_s)
  ref
end

info_plist_ref = tunnel_group.files.find { |f| f.path == 'Info.plist' } ||
                 tunnel_group.new_reference('Info.plist')
entitlements_ref = tunnel_group.files.find { |f| f.path == "#{TUNNEL_TARGET_NAME}.entitlements" } ||
                   tunnel_group.new_reference("#{TUNNEL_TARGET_NAME}.entitlements")

# ---------------------------------------------------------------------------
# Find-or-create the extension target itself.
# ---------------------------------------------------------------------------
tunnel_target = project.targets.find { |t| t.name == TUNNEL_TARGET_NAME }
if tunnel_target.nil?
  puts "Creating new PBXNativeTarget '#{TUNNEL_TARGET_NAME}'"
  tunnel_target = project.new_target(
    :app_extension,
    TUNNEL_TARGET_NAME,
    :osx,
    '11.0',
    nil,
    :swift,
  )
else
  puts "Updating existing PBXNativeTarget '#{TUNNEL_TARGET_NAME}'"
  # Wipe stale compile files so we re-add the full discovered set below.
  tunnel_target.source_build_phase.files_references.each do |ref|
    tunnel_target.source_build_phase.remove_file_reference(ref)
  end
end

# Add every Swift source to the target's compile phase.
swift_refs.each do |ref|
  tunnel_target.add_file_references([ref])
end

# Build settings the extension needs to actually run. Comments here mirror
# the in-tree macos/ArcaneDispatchTunnel/PacketTunnelProvider.swift docblock
# so the wiring + the runtime expectations don't drift.
tunnel_target.build_configurations.each do |config|
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER']     = TUNNEL_BUNDLE_ID
  s['PRODUCT_NAME']                  = '$(TARGET_NAME)'
  s['SWIFT_VERSION']                 = '5.0'
  s['MACOSX_DEPLOYMENT_TARGET']      = '11.0'
  s['SDKROOT']                       = 'macosx'
  s['INFOPLIST_FILE']                = TUNNEL_INFO_PLIST
  s['CODE_SIGN_ENTITLEMENTS']        = TUNNEL_ENTITLEMENTS
  s['CODE_SIGN_STYLE']               = 'Automatic'
  s['DEVELOPMENT_TEAM']              = DEVELOPMENT_TEAM
  s['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  s['ALWAYS_SEARCH_USER_PATHS']      = 'NO'
  s['CLANG_ENABLE_OBJC_ARC']         = 'YES'
  s['DEAD_CODE_STRIPPING']           = 'YES'
  s['CURRENT_PROJECT_VERSION']       = '1'
  s['MARKETING_VERSION']             = '1.0'
  s['GENERATE_INFOPLIST_FILE']       = 'NO'
  # Network Extensions get LSApplicationCategoryType-style packaging by
  # default; this disables the App Sandbox debug switch the Runner uses,
  # because the .appex must remain sandboxed even in debug.
  s['SKIP_INSTALL']                  = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS']       = [
    '$(inherited)',
    '@executable_path/../Frameworks',
    '@executable_path/../../../../Frameworks',
  ]
end

# Make sure the target's product is in the Products group (xcodeproj
# normally handles this on `new_target`, but re-running for updates we want
# to be defensive).
products_group = project.products_group
unless products_group.children.include?(tunnel_target.product_reference)
  products_group << tunnel_target.product_reference
end

# ---------------------------------------------------------------------------
# Embed the extension into Runner.app via a Copy Files build phase.
# ---------------------------------------------------------------------------
embed_phase = runner_target.copy_files_build_phases.find do |phase|
  phase.name == 'Embed App Extensions'
end
if embed_phase.nil?
  puts "Adding 'Embed App Extensions' phase to Runner"
  embed_phase = runner_target.new_copy_files_build_phase('Embed App Extensions')
  # dstSubfolderSpec 13 == PlugIns. The xcodeproj gem accepts a symbol via
  # #symbol_dst_subfolder_spec= but uses the numeric value internally.
  embed_phase.symbol_dst_subfolder_spec = :plug_ins
  embed_phase.dst_path = ''
  # The embed phase needs to run before the "Bundle Framework" copy and
  # the Flutter shell-script that re-runs `macos_assemble.sh`. Xcode's
  # convention is right after the link/sources phases.
  runner_target.build_phases.delete(embed_phase)
  insert_index = runner_target.build_phases.index do |ph|
    ph.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) && ph.name == 'Bundle Framework'
  end
  insert_index ||= runner_target.build_phases.length
  runner_target.build_phases.insert(insert_index, embed_phase)
end

# Make sure the embed phase contains exactly one reference to the extension's
# product .appex with the "Code Sign On Copy" attribute set.
embed_file = embed_phase.files_references.find { |r| r == tunnel_target.product_reference }
if embed_file.nil?
  build_file = embed_phase.add_file_reference(tunnel_target.product_reference)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy', 'CodeSignOnCopy'] }
else
  # Defensive: re-apply settings in case a prior run missed them.
  bf = embed_phase.files.find { |f| f.file_ref == tunnel_target.product_reference }
  if bf
    attrs = (bf.settings && bf.settings['ATTRIBUTES']) || []
    %w[RemoveHeadersOnCopy CodeSignOnCopy].each do |a|
      attrs << a unless attrs.include?(a)
    end
    bf.settings = { 'ATTRIBUTES' => attrs }
  end
end

# ---------------------------------------------------------------------------
# Make Runner depend on the extension so a Build builds both targets.
# ---------------------------------------------------------------------------
unless runner_target.dependencies.any? { |d| d.target == tunnel_target }
  puts "Adding Runner -> #{TUNNEL_TARGET_NAME} target dependency"
  runner_target.add_dependency(tunnel_target)
end

# ---------------------------------------------------------------------------
# Link NetworkExtension.framework (the extension Swift code already imports
# it; the linker needs the framework explicitly).
# ---------------------------------------------------------------------------
unless tunnel_target.frameworks_build_phase.files.any? do |f|
         f.file_ref && f.file_ref.path == 'System/Library/Frameworks/NetworkExtension.framework'
       end
  frameworks_group = project.frameworks_group
  ne_ref = frameworks_group.files.find { |f| f.path == 'System/Library/Frameworks/NetworkExtension.framework' }
  ne_ref ||= frameworks_group.new_file('System/Library/Frameworks/NetworkExtension.framework')
  ne_ref.source_tree = 'SDKROOT'
  tunnel_target.frameworks_build_phase.add_file_reference(ne_ref, true)
end

project.save

puts "Done. Project saved to #{PROJECT_PATH}/project.pbxproj"
