require "time"

require "rubygems"
require "maruku"
require "redcloth"

class FileModel
  attr_reader :filename, :mtime

  def self.model_path(basename = nil)
    Nesta::Configuration.content_path(basename)
  end

  def initialize(filename)
    @filename = filename
    @mtime = File.mtime(filename)
  end

  def last_modified
    @last_modified ||= File.stat(@filename).mtime
  end
end

class Page < FileModel
  FORMATS = [:mdown, :haml, :textile]
  @@cache = {}

  attr_reader :markup

  class << self
    def model_path(basename = nil)
      Nesta::Configuration.page_path(basename)
    end

    def find_all
      file_pattern = File.join(model_path, "**", "*.{#{FORMATS.join(',')}}")
      Dir.glob(file_pattern).map do |path|
        relative = path.sub("#{model_path}/", "")
        load(relative.sub(/\.(#{FORMATS.join('|')})/, ""))
      end
    end

    def find_by_path(path)
      load(path)
    end

    def find_articles
      find_all.select { |page| page.date }.sort { |x, y| y.date <=> x.date }
    end

    def needs_loading?(path, filename)
      @@cache[path].nil? || File.mtime(filename) > @@cache[path].mtime
    end

    def load(path)
      FORMATS.each do |format|
        filename = model_path("#{path}.#{format}")
        filename = File.join(model_path(path), "page.#{format}") unless File.exist?(filename)
        if File.exist?(filename) && needs_loading?(path, filename)
          @@cache[path] = self.new(filename)
          break
        end
      end
      @@cache[path]
    end

    def standalone?(page_path)
      page_pattern = File.join(model_path(page_path), "page.{#{FORMATS.join(',')}}")
      !Dir.glob(page_pattern).empty?
    end

    def stylesheet(page_path)
      if standalone?(page_path)
        style = File.join(model_path(page_path), "page.sass")
        style if File.exist?(style)
      end
    end

    def javascript(page_path)
      if standalone?(page_path)
        script = File.join(model_path(page_path), "page.js")
        script if File.exist?(script)
      end
    end

    def purge_cache
      @@cache = {}
    end

    def menu_items
      menu = Nesta::Configuration.content_path("menu.txt")
      pages = []
      if File.exist?(menu)
        File.open(menu).each { |line| pages << Page.load(line.chomp) }
      end
      pages
    end
  end

  def initialize(filename)
    @filename = filename
    @format = filename.split(".").last.to_sym
    parse_file
    super
  end

  def ==(other)
    self.path == other.path
  end

  def standalone?
    File.basename(@filename, ".*") == "page"
  end

  def permalink
    standalone? ? File.basename(File.dirname(@filename)) : File.basename(@filename, ".*")
  end

  def path
    abspath.sub(/^\//, "")
  end

  def abspath
    prefix = File.dirname(@filename).sub(Nesta::Configuration.page_path, "")
    standalone? ? prefix : File.join(prefix, permalink)
  end

  def heading
    regex = case @format
      when :mdown
        /^#\s*(.*)/
      when :haml
        /^\s*%h1\s+(.*)/
      when :textile
        /^\s*h1\.\s+(.*)/
      end
    markup =~ regex
    Regexp.last_match(1)
  end

  def to_html
    case @format
    when :mdown
      Maruku.new(markup).to_html
    when :haml
      Haml::Engine.new(markup).to_html
    when :textile
      RedCloth.new(markup).to_html
    end
  end

  def date(format = nil)
    @date ||= if metadata("date")
      if format == :xmlschema
        Time.parse(metadata("date")).xmlschema
      else
        DateTime.parse(metadata("date"))
      end
    end
  end

  def description
    metadata("description")
  end

  def keywords
    metadata("keywords")
  end

  def atom_id
    metadata("atom id")
  end

  def read_more
    metadata("read more") || "Continue reading"
  end

  def summary
    if summary_text = metadata("summary")
      summary_text.gsub!('\n', "\n")
      case @format
      when :textile
        RedCloth.new(summary_text).to_html
      else
        Maruku.new(summary_text).to_html
      end
    end
  end

  def body
    case @format
    when :mdown
      body_text = markup.sub(/^#[^#].*$\r?\n(\r?\n)?/, "")
      Maruku.new(body_text).to_html
    when :haml
      body_text = markup.sub(/^\s*%h1\s+.*$\r?\n(\r?\n)?/, "")
      Haml::Engine.new(body_text).render
    when :textile
      body_text = markup.sub(/^\s*h1\.\s+.*$\r?\n(\r?\n)?/, "")
      RedCloth.new(body_text).to_html
    end
  end

  def categories
    categories = metadata("categories")
    paths = categories.nil? ? [] : categories.split(",").map { |p| p.strip }
    valid_paths(paths).map { |p| Page.find_by_path(p) }.sort do |x, y|
      x.heading.downcase <=> y.heading.downcase
    end
  end

  def parent
    Page.load(File.dirname(path))
  end

  def pages
    Page.find_all.select do |page|
      page.date.nil? && page.categories.include?(self)
    end.sort do |x, y|
      x.heading.downcase <=> y.heading.downcase
    end
  end

  def articles
    Page.find_articles.select { |article| article.categories.include?(self) }
  end

  def standalone_file(file)
    if standalone?
      file = File.join(File.dirname(@filename), file)
      file if File.exist?(file)
    end
  end

  def stylesheet
    File.join(abspath, "page.css") if standalone_file("page.sass")
  end

  def javascript
    File.join(abspath, "page.js") if standalone_file("page.js")
  end

  private
    def metadata(key)
      @metadata[key]
    end

    def paragraph_is_metadata(text)
      text.split("\n").first =~ /^[\w ]+:/
    end

    def parse_file
      first_para, remaining = File.open(@filename).read.split(/\r?\n\r?\n/, 2)
      @metadata = {}
      if paragraph_is_metadata(first_para)
        @markup = remaining
        for line in first_para.split("\n") do
          key, value = line.split(/\s*:\s*/, 2)
          @metadata[key.downcase] = value.chomp
        end
      else
        @markup = [first_para, remaining].join("\n\n")
      end
    rescue Errno::ENOENT  # file not found
      raise Sinatra::NotFound
    end

    def valid_paths(paths)
      paths.select do |path|
        FORMATS.detect do |format|
          File.exist?(
              File.join(Nesta::Configuration.page_path, "#{path}.#{format}"))
        end
      end
    end
end

class Attachment < FileModel
  FORMATS = Page::FORMATS + [:sass]

  def self.find(attachment_path)
    filename = Nesta::Configuration.page_path(attachment_path)
    if File.exist?(filename) &&
     FORMATS.reject { |f| File.basename(attachment_path) != "page.#{f}" }.empty? && # the requested attachment isn't a special page file
     !Page::FORMATS.select { |f| File.exist?(File.join(File.dirname(filename), "page.#{f}")) }.empty? # the directory containing the attachment also has a page file
      filename
    else
      false
    end
  end
end
