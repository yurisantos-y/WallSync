#!/usr/bin/env ruby
# Incrementally syncs Wallpaper.xcodeproj with the files on disk without
# regenerating it (object IDs, scheme references and hand-tuned build settings
# are preserved). Run after adding, moving or deleting source files.

require "rubygems"
require "xcodeproj"

ROOT = File.expand_path("..", __dir__)
Dir.chdir(ROOT)

project = Xcodeproj::Project.open("Wallpaper.xcodeproj")
app_target = project.targets.find { |t| t.name == "Wallpaper" }
test_target = project.targets.find { |t| t.name == "WallpaperTests" }

def group_for(project, dir)
  group = project.main_group
  dir.split("/").each do |component|
    child = group.children.find { |c| c.isa == "PBXGroup" && (c.name == component || c.path == component) }
    group = child || group.new_group(component)
  end
  group
end

known = {}
project.files.each do |ref|
  path = ref.real_path
  next unless path.absolute? && path.to_s.start_with?(ROOT + "/")
  known[path.relative_path_from(Pathname.new(ROOT)).to_s] = ref
end

# Drop references to files that no longer exist.
known.each do |path, ref|
  next if File.exist?(path)
  next unless path.start_with?("Wallpaper/", "Tests/")
  ref.build_files.each(&:remove_from_project)
  ref.remove_from_project
  puts "removed #{path}"
end

Dir.glob("{Wallpaper,Tests}/**/*").sort.each do |path|
  next if File.directory?(path) && !path.end_with?(".xcassets")
  next if path.include?(".xcassets/")
  next if known.key?(path)
  ext = File.extname(path)
  next unless [".swift", ".xcstrings", ".xcassets"].include?(ext)

  ref = group_for(project, File.dirname(path)).new_file(File.join(ROOT, path))
  case ext
  when ".swift"
    target = path.start_with?("Tests/") ? test_target : app_target
    target.source_build_phase.add_file_reference(ref, true)
  else
    app_target.resources_build_phase.add_file_reference(ref, true)
  end
  puts "added #{path}"
end

regions = project.root_object.known_regions
%w[en pt-BR Base].each { |region| regions << region unless regions.include?(region) }
project.root_object.known_regions = regions

project.save
