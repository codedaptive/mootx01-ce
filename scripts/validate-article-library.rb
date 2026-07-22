#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "pathname"

PRIVATE_MARKERS = [
  /\bSuggested (?:use|publish|preview|title|subtitle|tags|link placement)\b/i,
  /\bSchedule target\b/i,
  /\bStatus:\s*(?:working|draft|ready|pending)/i,
  /\bOptional First Comment\b/i,
  /\bWorking Source Notes\b/i,
  /\bTEXT MARKER\b/i,
  /\[Substack link\]/i,
  %r{/Users/bob/},
  /\bREVIEW REQUIRED\b/
].freeze

options = { root: "docs/articles", allow_empty: false }
OptionParser.new do |parser|
  parser.banner = "usage: validate-article-library.rb [options]"
  parser.on("--root PATH") { |value| options[:root] = value }
  parser.on("--allow-empty") { options[:allow_empty] = true }
end.parse!

root = File.expand_path(options[:root])
problems = []

%w[README.md business/README.md technical/README.md].each do |relative|
  problems << "missing #{relative}" unless File.file?(File.join(root, relative))
end

lanes = %w[business technical].to_h do |lane|
  paths = Dir.glob(File.join(root, lane, "*.md")).reject { |path| File.basename(path) == "README.md" }
  [lane, paths.sort]
end

business_names = lanes.fetch("business").map { |path| File.basename(path) }
technical_names = lanes.fetch("technical").map { |path| File.basename(path) }

if business_names.empty? && technical_names.empty?
  problems << "article library is empty" unless options[:allow_empty]
elsif business_names != technical_names
  problems << "business and technical editions do not have matching filenames"
end

lanes.each do |lane, paths|
  paths.each do |path|
    relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
    markdown = File.read(path, encoding: "UTF-8")

    problems << "#{relative} must begin with one title" unless markdown.match?(/\A# .+\n/)
    problems << "#{relative} contains an article wrapper" if markdown.match?(/^## Article\s*$/)
    problems << "#{relative} lacks the series index link" unless markdown.include?("[Series index](../README.md)")
    problems << "#{relative} lacks an original publication link" unless markdown.match?(/Originally published on \[[^\]]+\]\(https:\/\//)

    paired_lane = lane == "business" ? "technical" : "business"
    paired_label = lane == "business" ? "Technical edition" : "Business edition"
    expected_pair = "[#{paired_label}](../#{paired_lane}/#{File.basename(path)})"
    problems << "#{relative} lacks its paired edition link" unless markdown.include?(expected_pair)

    PRIVATE_MARKERS.each do |pattern|
      problems << "#{relative} leaks editorial marker #{pattern.inspect}" if markdown.match?(pattern)
    end

    markdown.scan(/\[[^\]]*\]\(([^)]+)\)/).flatten.each do |target|
      next if target.match?(%r{\Ahttps?://}) || target.start_with?("#", "mailto:")

      resolved = File.expand_path(target, File.dirname(path))
      problems << "#{relative} has broken local link #{target}" unless File.exist?(resolved)
    end
  end
end

if problems.empty?
  puts "PASS article library: #{business_names.length} paired article(s)"
  exit 0
end

problems.each { |problem| warn "FAIL: #{problem}" }
exit 1
