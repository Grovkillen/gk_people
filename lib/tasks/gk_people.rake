# frozen_string_literal: true

# Company data read from the command line, the same code as the page (GkPeople::CompanyData), up to the file's limits:
#   bin/rails gk_people:foretagsdata:preview FILE=D:\data\foretagsdata_20261013.jsonl MANIFEST=D:\data\foretagsdata_manifest.json
#                                            KOMMUN=2305,2380 LOGIN=admin RAILS_ENV=production
#   bin/rails gk_people:foretagsdata:import  (the same)
# FILE is the file; MANIFEST its manifest.json (optional, the file is then checked against it); KOMMUN the municipalities
# to read (at least one; KOMMUN=? lists the file's); LOGIN an administrator; SOLE_TRADERS=0 leaves sole traders out;
# SOURCE and SOURCE_ON the source and its date when manifest.json and the file name do not give them; RESULT a path for
# the counts as JSON; LIST (new, update, held, review, rejected) prints that list. preview keeps nothing.
# A real file never lies in a synced folder (Dropbox, OneDrive): the task says so when it does.
namespace :gk_people do
  namespace :foretagsdata do
    def gk_company_run(commit)
      # the reading is closed without GK GUI Stuff, like the pages (GkPeople::Gate.line, gate.rb); the line is the
      # settings page's, read from the locale files, and says the first thing that is not met
      closed = GkPeople::Gate.line
      abort(closed) if closed
      cd = GkPeople::CompanyData
      file = ENV['FILE'].to_s
      abort 'FILE= is needed' if file.empty? || !File.file?(file)
      warn "Varning: #{file} ligger i en mapp som synkas. En riktig fil ska aldrig ligga där." if cd.synced_path?(file)
      manifest = ENV['MANIFEST'].presence
      warn 'Varning: inget manifest (MANIFEST=); filen prövas inte mot sin sha256.' unless manifest
      manifest &&= File.read(manifest, mode: 'r:bom|utf-8')
      login = ENV['LOGIN'].to_s
      abort 'LOGIN= is needed (an administrator)' if login.empty?

      codes = ENV['KOMMUN'].to_s.split(',').map(&:strip).reject(&:empty?)
      ActiveRecord::Base.logger = nil
      started = Time.current
      puts GkPeople::CompanyData.data_controller_text
      if codes == ['?'] || codes.empty?
        rows = cd.scan(file)
        rows[:municipalities].each { |c, m| puts "#{c} #{m['name']}: #{m['workplaces']} arbetsställen, #{m['organizations']} organisationer" }
        abort 'KOMMUN= is needed (at least one of the codes above)'
      end
      result = cd.run_path!(file, codes: codes, login: login, manifest: manifest, commit: commit, sole_traders: ENV['SOLE_TRADERS'].to_s != '0',
                                  source: ENV['SOURCE'].presence, source_on: ENV['SOURCE_ON'].presence,
                                  progress: ->(done, all) { puts "  #{done}/#{all} (#{(Time.current - started).round} s)" if (done % 1000).zero? || done == all })
      c = result[:counts]
      puts c.map { |k, v| "#{k}: #{v}" }.join(', ')
      if (list = ENV['LIST'].presence)
        test = { 'new' => ->(r) { r['action'] == 'new' }, 'update' => ->(r) { r['action'] == 'update' }, 'held' => ->(r) { Array(r['held']).any? },
                 'review' => ->(r) { Array(r['review']).any? }, 'rejected' => ->(r) { r['action'] == 'rejected' } }.fetch(list)
        result[:preview].select(&test).first(200).each { |r| puts "  rad #{r['line']}: #{r['name']} #{(Array(r['errors']) + Array(r['held']).map { |h| h['field'] }).join(', ')}" }
      end
      seconds = (Time.current - started).round(1)
      puts "#{commit ? 'Inläst' : 'Förhandsgranskat, inget sparat'} på #{seconds} s."
      if (out = ENV['RESULT'].presence)
        File.write(out, JSON.pretty_generate({ action: commit ? 'import' : 'preview', counts: c, seconds: seconds,
                                               municipalities: result[:municipalities], selection: codes }))
      end
    rescue ArgumentError => e
      warn e.message
      exit 1
    end

    desc 'Preview company data (FILE, MANIFEST, KOMMUN, LOGIN): what a reading would make, change, hold and count; nothing is kept'
    task preview: :environment do
      gk_company_run(false)
    end

    desc 'Read company data into the instance (FILE, MANIFEST, KOMMUN, LOGIN)'
    task import: :environment do
      gk_company_run(true)
    end

    desc 'Write a made-up company data file and its manifest for a volume test (OUT, ROWS, SEED, KOMMUN); never a real file'
    task generate: :environment do
      abort 'the made-up files are written by the scenario tool (GK Scenarios)' unless defined?(GkPeople::Scenarios) && GkPeople::Scenarios.respond_to?(:company_data_volume)

      out = ENV['OUT'].to_s
      abort 'OUT= is needed' if out.empty?
      abort "#{out} ligger i en mapp som synkas; skriv provfilen utanför." if GkPeople::CompanyData.synced_path?(out)

      paths = GkPeople::Scenarios.company_data_volume(out, rows: (ENV['ROWS'].presence || 20_000).to_i, seed: (ENV['SEED'].presence || 128).to_i,
                                                           codes: ENV['KOMMUN'].to_s.split(',').map(&:strip).reject(&:empty?).presence || %w[2305 2380])
      puts paths.join("\n")
    end
  end
end
