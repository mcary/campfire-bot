require 'yaml'

# Remember quotes and quips added upon request.
#
# Since this plugin maintains long-term persistent data,
# not just temporary state, its data file lives under var/
# instead of tmp/.
#
# You can import from the eggdrop QuoteBot.log with this, which will
# overwrite any existing campfire-bot quotes:
#
#   ruby -e '
#     require "yaml"
#     log = File.readlines("QuoteBot.log").collect { |l|
#       action, scope, quoter, room, id, quote = l.split(" ", 6)
#       [action, quoter, room, id.sub(/^[(]#/, "").sub(/[)]$/, "").to_i,
#        nil, quote]
#     }
#     File.open("var/quote-log.yml", "w") do |out|
#       YAML.dump(log, out)
#     end
#     puts "wrote #{log.size} log entries"
#   '
#
# Issues:
#
# * The entire log is rewritten after each add/del, which takes 1.2 sec
#   for my 3k quotes.  It's the YAML.dump call that's slow.  An alternative
#   would be to store each log entry as a document and only append to the
#   file.  However, an incomplete write would corrupt the file.  Maybe there's
#   a way to discard the last, corrupt yaml document?
#
# * Would be nice when there are multiple matches to iterate through them
#   when the same query is repeated.
#
class Quote < CampfireBot::Plugin
  on_command 'addquote', :addquote
  on_command 'quote', :quote
  on_command 'rmquote', :rmquote

  def self.config_var(name, default)
    attr_reader name
    @@config_defaults ||= {}
    @@config_defaults[name] = default
  end

  config_var :data_file, File.join(BOT_ROOT, 'var', 'quote-log.yml')
  config_var :debug_enabled, false

  def initialize()
    @@config_defaults.each_pair { |name, default|
      instance_variable_set("@#{name.to_s}",
                            bot.config["quote_#{name.to_s}"] || default)
    }

    @log = begin
        YAML::load(File.read(@data_file))
      rescue Errno::ENOENT => e
        debug e
        []
      end
  end

  def debug(spew)
    $stderr.puts "#{self.class.name}: #{spew}" if debug_enabled
  end

  def addquote(msg)
    debug "Addquote requested: #{msg}"
    if msg[:message].empty?
      msg.speak "Please include the text of the quote and attribution."
      return
    end
    append_add(msg[:person], msg[:room].name, msg[:message])
    # Show the users quote numberes that start with 1 not 0
    msg.speak "Added quote ##{quotes.length}."
  end

  def append_add(quoter, room, quote)
    debug "ADD: #{quotes.length + 1} #{quote}"
    @log.push ["ADD", quoter, room, quotes.length + 1, Time.now, quote]
    write_log
  end

  def quote(msg)
    q = msg[:message]
    id = q.to_i
    # If numeric
    if id.to_s == q
      msg.speak quotes[id - 1] ? format_quote(id) : "No quote ##{id}."
    else
      matches = select_quote_ids {|quote| quote.include?(q) }
      msg.speak matches.empty? ?
        "No matching quotes." :
        format_quote(matches[rand(matches.length)]) +
          (q == "" ? "" :
           " (#{matches.size} match#{"es" if matches.size != 1})")
    end
  end

  def format_quote(id)
    "##{id} #{quotes[id - 1]}"
  end

  def select_quote_ids
    returning([]) {|ids|
      quotes.each_with_index {|quote,idx|
        if !quote.nil? && yield(quote)
          ids.push(idx + 1)
        end
      }
    }
  end

  def rmquote(msg)
    q = msg[:message]
    id = q.to_i
    # If numeric
    if id.to_s != q || !quotes[id - 1]
      msg.speak "No quote ##{q}."
      return
    end
    append_del(msg[:person], msg[:room].name, id)
    msg.speak "Deleted quote ##{id}."
  end

  def append_del(rmer, room, id)
    debug "DEL: #{quotes.length} #{id}"
    @log.push ["DEL", rmer, room, id, Time.now, nil]
    write_log
  end

  def quotes
    return @quotes if @quotes
    debug "Rebuilding @quotes from @log of length #{@log.size}"
    @quotes = []
    @log.each { |action, quoter, room, id, ts, quote|
      case action
        when "ADD" then
          raise "Bad ID: #{id}" if id - 1 != @quotes.length
          @quotes.push quote
        when "DEL" then
          @quotes[id - 1] = nil
          # Allow any trailing IDs with nil quotes to be reused
          @quotes.pop while @quotes.last.nil? && !@quotes.empty?
        else raise "Unknown log action #{action}"
      end
    }
    @quotes
  end

  def write_log
    debug "Writing #{@log.length} log entries"
    File.open("#{data_file}.tmp", 'w') do |out|
      YAML.dump(@log, out)
    end
    debug "Renaming .tmp file to #{data_file}"
    File.rename("#{data_file}.tmp", data_file)
    @quotes = nil
  end
end
