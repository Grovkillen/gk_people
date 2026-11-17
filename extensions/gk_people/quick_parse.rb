# frozen_string_literal: true

# gk_people, the reading of a quick contact's line. Plain Ruby, no Rails (test/core_test.rb runs it): the rules are
# fixed here, the list of roles and departments is data and comes in as an argument, and so does the question whether a
# name is a known organization (known_org), so the database stays out of it.
#
# One line, parts separated by commas, in any order:
# * a part with @ is the e-mail (when it looks like one; otherwise it goes to the description);
# * NNNNNN-NNNN is an organization number;
# * a telephone number (at least six digits, only digits, spaces, + - ( ) / .) is the telephone;
# * a part with a company form (AB, HB, KB, ek. för., aktiebolag, ekonomisk förening) or a known organization's name is
#   the organization;
# * a word from the list of roles and departments ("ekonomi", also written "på ekonomi") is the role;
# * the first part with no other reading is the name, the rest the description;
# * "?" right after a part makes that part uncertain and the post partly verified (unverified where the place does not
#   have partly verified, status); "osäkert" as a part of its own makes the whole post unverified.
# One of each (name, e-mail, telephone, organization number, organization); a second one goes to the description.
module GkPeople
  module QuickParse
    FIELDS = %w[name email phone org_no organization role description].freeze
    # the fields a part may be moved to afterwards (the organization number only through the line itself)
    MOVABLE = %w[name email phone organization role description].freeze
    UNSURE = %w[osäkert osäker osakert osaker].freeze
    ORG_NO = /\A\d{6}-\d{4}\z/
    EMAIL = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    PHONE = %r{\A\+?[\d\s\-()/.]+\z}
    # company forms, as words; "ek. för." also without the dots and spaces
    FORMS = [/(?<![[:alnum:]])(ab|hb|kb)(?![[:alnum:]])/i, /(?<![[:alnum:]])ek\.?\s*för\.?(?![[:alnum:]])/i,
             /(?<![[:alnum:]])ekonomisk\s+förening(?![[:alnum:]])/i, /(?<![[:alnum:]])aktiebolag(?![[:alnum:]])/i,
             /(?<![[:alnum:]])handelsbolag(?![[:alnum:]])/i, /(?<![[:alnum:]])kommanditbolag(?![[:alnum:]])/i,
             /\(publ\)/i].freeze
    ONE_ONLY = %w[name email phone org_no organization].freeze
    LIMITS = { 'first_name' => 100, 'last_name' => 100, 'email' => 200, 'phone' => 60, 'title' => 120, 'org_name' => 200, 'org_no' => 40 }.freeze

    module_function

    # Several pasted lines: one post per line that has something on it
    def lines(text) = text.to_s.split(/\r?\n/).map(&:strip).reject(&:empty?)

    # { text:, parts: [{ 'i', 'text', 'field', 'uncertain' }], unverified: } (parts in the order written; the part
    # "osäkert" itself is kept with the field 'unsure', so the line can be shown as it was read)
    def parse(line, roles: [], known_org: nil)
      text = line.to_s.strip
      role_list = Array(roles).map { |r| r.to_s.strip }.reject(&:empty?)
      unverified = false
      parts = []
      text.split(',').map(&:strip).reject(&:empty?).each do |raw|
        uncertain = raw.end_with?('?')
        clean = raw.sub(/\s*\?+\z/, '').strip
        next if clean.empty?

        if UNSURE.include?(clean.downcase)
          unverified = true
          parts << { 'text' => clean, 'field' => 'unsure', 'uncertain' => false }
          next
        end
        field, value = classify(clean, role_list, known_org)
        parts << { 'text' => value, 'field' => field, 'uncertain' => uncertain }
      end
      seen = {}
      parts.each do |p|
        f = p['field']
        if f == 'free'
          p['field'] = seen['name'] ? 'description' : 'name'
        elsif ONE_ONLY.include?(f) && seen[f]
          p['field'] = 'description'
        end
        seen[p['field']] = true
      end
      parts.each_with_index { |p, i| p['i'] = i }
      { text: text, parts: parts, unverified: unverified }
    end

    # [field, the text kept]; free: no reading of its own (the name or the description, decided by the order)
    def classify(part, roles, known_org)
      if part.include?('@')
        e = part.delete(' ')
        return e.match?(EMAIL) ? ['email', e] : ['free', part]
      end
      return ['org_no', part] if part.match?(ORG_NO)
      return ['phone', part] if phone?(part)
      return ['organization', part] if company_form?(part)

      role = role_of(part, roles)
      return ['role', role] if role
      return ['organization', part] if known_org.respond_to?(:call) && known_org.call(part)

      ['free', part]
    end

    def phone?(part) = part.match?(PHONE) && part.count('0-9') >= 6

    def company_form?(part) = FORMS.any? { |re| part.match?(re) }

    # The word from the list as written there, for "ekonomi", "Ekonomi" or "på ekonomi"; nil when it is none
    def role_of(part, roles)
      p = part.to_s.strip.sub(/\Apå\s+/i, '').strip.downcase
      return nil if p.empty?

      roles.detect { |r| r.downcase == p }
    end

    # The values the parts give: { 'name', 'email', 'phone', 'org_no', 'organization', 'role', 'description' }; role
    # and description joined with ", " when there are several
    def values(parts)
      out = {}
      Array(parts).each do |p|
        f = p['field']
        next unless FIELDS.include?(f)

        out[f] = %w[role description].include?(f) && out[f] ? "#{out[f]}, #{p['text']}" : (out[f] || p['text'])
      end
      out
    end

    # The verification step a line gives on a place, and whether "?" fell back: "osäkert" gives unverified, a part with
    # "?" partly_verified, nothing said nothing. levels are the levels on the place (nil: every level); where
    # partly_verified is not among them, "?" gives unverified and fell_back is true. [step or nil, fell_back]
    def status(parsed, levels = nil)
      return ['unverified', false] if parsed[:unverified]
      return [nil, false] unless Array(parsed[:parts]).any? { |p| p['uncertain'] }
      return ['partly_verified', false] if levels.nil? || Array(levels).map(&:to_s).include?('partly_verified')

      ['unverified', true]
    end

    # Does the line name a person (a name, an e-mail or a telephone); otherwise it makes only an organization
    def personish?(vals) = !(vals['name'] || vals['email'] || vals['phone']).nil?

    # "Lotta" -> ["Lotta", nil]; "Lotta Andersson" -> ["Lotta", "Andersson"]; "Anna Maria von Ek" -> ["Anna", "Maria von Ek"]
    def split_name(name)
      words = name.to_s.strip.split(/\s+/)
      return [nil, nil] if words.empty?

      [words.first[0, LIMITS['first_name']], words.size > 1 ? words.drop(1).join(' ')[0, LIMITS['last_name']] : nil]
    end

    # An organization's name compared without case, company form and punctuation: "Företag AB" and "företag" are one
    def norm_org(name)
      s = name.to_s.downcase
      FORMS.each { |re| s = s.gsub(re, ' ') }
      s.gsub(/[^[:alnum:]\s]/, ' ').split.join(' ')
    end

    # The words of a name worth searching for (three letters or more), for a first narrowing in the database
    def org_words(name) = norm_org(name).split.select { |w| w.length >= 3 }

    # Similar organization names, for the suggestion to merge: the same once normalized, one the beginning of the
    # other (four letters or more), or a few letters apart
    def similar_org?(a, b)
      x = norm_org(a)
      y = norm_org(b)
      return false if x.empty? || y.empty?
      return true if x == y

      short, long = [x, y].sort_by(&:length)
      return true if short.length >= 4 && long.start_with?(short)

      return true if close?(x, y)
    
      # a one-word name and the first word of a longer one ("Trädfällare" and "Trädfällarna i Bräcke"), five letters or more
      wx = x.split
      wy = y.split
      (wx.size == 1 || wy.size == 1) && wx.first.length >= 5 && wy.first.length >= 5 && close?(wx.first, wy.first)
    end
    
    # A few letters apart: two from ten letters, one from seven, none below (so "Kund A" and "Kund B" stay apart)
    def close?(x, y)
      max = [x.length, y.length].max
      allowed = max >= 10 ? 2 : (max >= 7 ? 1 : 0)
      return x == y if allowed.zero?
    
      (x.length - y.length).abs <= allowed && distance(x, y) <= allowed
    end

    # Levenshtein distance, for short names only
    def distance(a, b)
      prev = (0..b.length).to_a
      a.each_char.with_index(1) do |ca, i|
        cur = [i]
        b.each_char.with_index(1) { |cb, j| cur << [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca == cb ? 0 : 1)].min }
        prev = cur
      end
      prev.last
    end

    # The domain of an e-mail address, for the organization it suggests: "lotta@foretag.example" -> "foretag.example"
    def domain(email)
      d = email.to_s.split('@', 2)[1].to_s.downcase.strip
      d.empty? ? nil : d
    end

    # The domain of a web address: "https://www.foretag.example/om" -> "foretag.example"
    def web_domain(url)
      h = url.to_s.strip.downcase.sub(%r{\A[a-z]+://}, '').split(%r{[/?#:]}, 2).first.to_s
      h = h.sub(/\Awww\./, '')
      h.empty? ? nil : h
    end
  end
end

