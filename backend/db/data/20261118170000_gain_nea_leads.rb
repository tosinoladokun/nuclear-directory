# Crawl, #257 and #805 (PM-approved discovery): company leads from two lists, for the finder to find, check (US,
# nuclear) and propose like any other lead. A list is never a source: only each company's own pages are.
# - GAIN (DOE/INL, Aug 2026): 112 company websites missing from the directory, the sites only (none of the list's text).
# - NEA SMR Dashboard (3rd edition, 2025): 9 developers missing from the directory, by name.
#
# Idempotent: a lead seen again only updates its own sighting.
class GainNeaLeads < DeployData::Migration
  BY = "human:tosin"
  GAIN_LABEL = "Lead list (Aug 2026), not a source"
  NEA_LABEL = "Lead list (NEA 2025), not a source"
  GAIN = %w[
    https://aalo.com
    https://alphatechresearchcorp.com
    https://deepfission.com
    https://exodysenergy.com
    https://fanuclear.com
    https://flibe.com
    https://hadronenergy.com
    https://holosgen.com
    https://hybridpwr.com
    https://micronucleartech.com
    https://mobilenuclear.energy
    https://muonsinc.com
    https://nanonuclearenergy.com
    https://naturaresources.com
    https://neutronixenergy.com
    https://niowaveinc.com
    https://nuclearisenergy.com
    https://nucube.energy
    https://nucdev.com
    https://terrestrialusa.com
    https://thorconpower.com
    https://aecom.com
    https://aecon.com
    https://alphasourceintl.com
    https://ansys.com
    https://atsindustrialautomation.com
    https://beaudrey.com
    https://bechtel.com
    https://bluestonego.com
    https://bnl.com
    https://burnsmcd.com
    https://carolinafab.com
    https://comprex-llc.com
    https://ctc.com
    https://cwnuclear.com
    https://dbdinternational.com
    https://dcfab.com
    https://dubosenes.com
    https://efinemetals.com
    https://empyreanonline.com
    https://emc-sq.com
    https://epm-inc.com
    https://excelservices.com
    https://exyn.com
    https://fjspecialty.com
    https://fauske.com
    https://emerson.com
    https://fisonic.us
    https://fluor.com
    https://geiconsultants.com
    https://gses.com
    https://gutor.com
    https://hanselltierney.com
    https://munichre.com
    https://haywardtyler.com
    https://hightemperaturesystemdesigns.com
    https://hukari.com
    https://hytorc.com
    https://islinc.com
    https://jensenhughes.com
    https://josephoat.com
    https://kinectrics.com
    https://lnh.net
    https://ltbridge.com
    https://maidana-research.com
    https://masterlee.com
    https://materion.com
    https://meridian-sg.com
    https://merrick.com
    https://millennitek.com
    https://mpmachineryandtesting.com
    https://mstechnology.com
    https://nelcoworldwide.com
    https://necenergy.com
    https://nuclearrosellc.com
    https://numerical.com
    https://nutherm.com
    https://nuvisionengineering.com
    https://paragones.com
    https://parsons.com
    https://pmtnuclear.com
    https://psstech.com
    https://pcc-york.com
    https://ptius.net
    https://qway.one
    https://radqual.com
    https://rockwellautomation.com
    https://rockewllautomation.com
    https://scottmadden.com
    https://sgh.com
    https://socotec.us
    https://swri.org
    https://standardnuclear.com
    https://sra-or.com
    https://structint.com
    https://studsvik.com
    https://systemone.com
    https://sics-c.org
    https://tetratech.com
    https://babcockpower.com
    https://thoriumenergyalliance.com
    https://tiogapipe.com
    https://transcoproducts.com
    https://william-cook.co.uk
    https://anl.gov
    https://lbl.gov
    https://llnl.gov
    https://sandia.gov
    https://srnl.gov
    https://ammt.anl.gov
    https://energy.sandia.gov
    https://mpact.lanl.gov
  ].freeze
  NEA = [ "Deep Fission", "Flibe Energy", "MobileNuclear Energy", "NANO Nuclear Energy", "ThorCon International", "Terrestrial Energy", "Blue Capsule Technology", "Stratek Global", "Otrera New Energy" ].freeze

  def up
    gain = GAIN.count do |url|
      host = URI.parse(url).host.to_s.delete_prefix("www.")
      Lead.sighted!(name: url, kind: "company", key: "gain-2026-08:#{host}", label: GAIN_LABEL, url:)
    end
    nea = NEA.count { |name| Lead.sighted!(name:, kind: "company", key: "nea-smr-3:#{Lead.normalize(name)}", label: NEA_LABEL) }
    say "Leads: #{gain} from GAIN's list, #{nea} from NEA's"
  end
end
