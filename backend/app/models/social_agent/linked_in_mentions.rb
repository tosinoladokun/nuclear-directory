# LinkedIn company mentions (PM, 21 Nov): Buffer's LinkedIn post input takes `metadata.linkedin.annotations`, each an
# AnnotationInputLinkedIn { id, entity: "urn:li:organization:<id>", start, length, link, localizedName, vanityName }, so a company's name in
# the text can be a real mention (a typed "@Name" is only text). The numeric organisation id is what LinkedIn needs and what we can't
# look up ourselves (LinkedIn refuses our fetch): config/social_linkedin_mentions.yml holds only the ones a person confirmed.
module SocialAgent::LinkedInMentions
  module_function

  def entries = @entries ||= YAML.safe_load_file(Rails.root.join("config/social_linkedin_mentions.yml")) || {}
  def entries=(value)
    @entries = value
  end

  # The annotations for the first plain occurrence of each configured company name in the text.
  def in(text)
    entries.values.filter_map do |entry|
      name = entry["name"].to_s
      index = text.index(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/)
      next if name.blank? || index.nil? || entry["id"].to_s !~ /\A\d+\z/ || entry["vanity"].to_s.blank?

      { id: entry["id"].to_s, entity: "urn:li:organization:#{entry['id']}", start: index, length: name.length,
        link: "https://www.linkedin.com/company/#{entry['vanity']}", localizedName: name, vanityName: entry["vanity"].to_s }
    end.sort_by { |annotation| annotation[:start] }
  end
end
