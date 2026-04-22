#!/usr/bin/env ruby

require "rubygems"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
Dir.chdir(ROOT)

project = Xcodeproj::Project.new("Wallpaper.xcodeproj")
app_target = project.new_target(:application, "Wallpaper", :osx, "14.0")
test_target = project.new_target(:unit_test_bundle, "WallpaperTests", :osx, "14.0")

[app_target, test_target].each do |target|
  target.build_configurations.each do |config|
    config.build_settings["SWIFT_VERSION"] = "6.0"
    config.build_settings["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    config.build_settings["CLANG_ENABLE_MODULES"] = "YES"
    config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
    config.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  end
end

app_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.yurisantos.wallpaper"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "NO"
  config.build_settings["INFOPLIST_FILE"] = "Wallpaper/Resources/Info.plist"
  config.build_settings["CODE_SIGN_ENTITLEMENTS"] = "Wallpaper/Resources/Wallpaper.entitlements"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  config.build_settings["ENABLE_HARDENED_RUNTIME"] = "YES"
  config.build_settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
end

test_target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.yurisantos.wallpaper.tests"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["TEST_HOST"] = "$(BUILT_PRODUCTS_DIR)/Wallpaper.app/Contents/MacOS/Wallpaper"
  config.build_settings["BUNDLE_LOADER"] = "$(TEST_HOST)"
end

test_target.add_dependency(app_target)

root_group = project.main_group
wallpaper_group = root_group.new_group("Wallpaper")
tests_group = root_group.new_group("Tests")

def add_directory(group:, path:, target:, test_target: nil)
  Dir.children(path).sort.each do |entry|
    full_path = File.join(path, entry)

    if File.directory?(full_path)
      if full_path.end_with?(".xcassets")
        ref = group.new_file(full_path)
        target.resources_build_phase.add_file_reference(ref, true)
      elsif full_path.end_with?(".appiconset")
        next
      else
        subgroup = group.new_group(entry)
        add_directory(group: subgroup, path: full_path, target: target, test_target: test_target)
      end
      next
    end

    ref = group.new_file(full_path)
    case File.extname(full_path)
    when ".swift"
      if full_path.start_with?("Tests/")
        test_target&.source_build_phase&.add_file_reference(ref, true)
      else
        target.source_build_phase.add_file_reference(ref, true)
      end
    when ".xcstrings"
      target.resources_build_phase.add_file_reference(ref, true)
    when ".plist"
      next if full_path.end_with?("Info.plist") || full_path.end_with?(".entitlements")
      target.resources_build_phase.add_file_reference(ref, true)
    end
  end
end

add_directory(group: wallpaper_group, path: "Wallpaper", target: app_target, test_target: test_target)
add_directory(group: tests_group, path: "Tests", target: app_target, test_target: test_target)

project.save
