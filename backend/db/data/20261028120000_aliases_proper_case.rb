# Design's 27 Oct audit (PM): "Also known as" showed registry names in ALL
# CAPS ("AMPEERS LLC", "BWXT NUCLEAR OPERATIONS GROUP, INC."), copied from
# USAspending and NRC. Same names, proper case; the three that only repeat the
# company's own name (BWXT, ENERCON, NASA) stay as they are: Lookup finds a
# company by its name through that alias. Acronyms (EPRI, ORNL, TVA) stay. The matcher compares a
# normalized form (case and legal suffix dropped), so no match changes. Merging this PR is Tosin's approval.
class AliasesProperCase < DeployData::Migration
  BY = "human:tosin"
  # alias id => [ the text it has now, its proper-case text ]
  CHANGES = {
    165 => [ "3M COMPANY", "3M Company" ], # 3M
    156 => [ "ADVANCED REACTOR CONCEPTS, LLC", "Advanced Reactor Concepts, LLC" ], # Advanced Reactor Concepts
    175 => [ "AMPEERS LLC", "Ampeers LLC" ], # Ampeers
    163 => [ "ANALYSIS AND MEASUREMENT SERVICES CORPORATION", "Analysis and Measurement Services Corporation" ], # Analysis and Measurement Services
    174 => [ "AQWEST, LLC", "Aqwest, LLC" ], # Aqwest
    158 => [ "BLUE WAVE CAPITAL AND CONSULTING LLC", "Blue Wave Capital and Consulting LLC" ], # Blue Wave Capital and Consulting
    179 => [ "BRIDGE 12 TECHNOLOGIES, INC.", "Bridge 12 Technologies, Inc." ], # Bridge12
    180 => [ "BROOKHAVEN TECHNOLOGY GROUP INC", "Brookhaven Technology Group Inc" ], # Brookhaven Technology Group
    162 => [ "BWXT NUCLEAR ENERGY, INC.", "BWXT Nuclear Energy, Inc." ], # BWXT
    208 => [ "BWXT NUCLEAR OPERATIONS GROUP, INC.", "BWXT Nuclear Operations Group, Inc." ], # BWXT
    157 => [ "CERAMIC TUBULAR PRODUCTS LLC", "Ceramic Tubular Products LLC" ], # Ceramic Tubular Products
    160 => [ "CONTAINER TECHNOLOGIES INDUSTRIES, LLC", "Container Technologies Industries, LLC" ], # Container Technologies Industries
    161 => [ "ELECTRIC POWER RESEARCH INSTITUTE INC", "Electric Power Research Institute Inc" ], # Electric Power Research Institute
    207 => [ "ENERGY HARBOR CORP.", "Energy Harbor Corp." ], # Energy Harbor Nuclear Corp.
    169 => [ "ENSCO INC", "ENSCO Inc" ], # ENSCO
    205 => [ "GE VERNOVA OPERATIONS LLC", "GE Vernova Operations LLC" ], # GE Vernova
    167 => [ "GOOD ENERGY COLLECTIVE INCORPORATED", "Good Energy Collective Incorporated" ], # Good Energy Collective
    170 => [ "LEIDOS, INC.", "Leidos, Inc." ], # Leidos
    172 => [ "LODESTAR RESEARCH CORPORATION", "Lodestar Research Corporation" ], # Lodestar Research
    166 => [ "NAC INTERNATIONAL INC.", "NAC International Inc." ], # NAC International
    168 => [ "NUCLEAR FUEL SERVICES INC", "Nuclear Fuel Services Inc" ], # Nuclear Fuel Services
    155 => [ "NUSCALE POWER LLC", "NuScale Power LLC" ], # NuScale Power
    173 => [ "NUSENICS, LLC", "Nusenics, LLC" ], # Nusenics
    159 => [ "NUVISION ENGINEERING, INC", "NuVision Engineering, Inc" ], # NuVision Engineering
    164 => [ "PKMJ TECHNICAL SERVICES, LLC", "PKMJ Technical Services, LLC" ], # PKMJ Technical Services
    177 => [ "PLASMA PROCESSES, LLC", "Plasma Processes, LLC" ], # Plasma Processes
    206 => [ "SOUTHERN COMPANY SERVICES, INC.", "Southern Company Services, Inc." ], # Southern Company
    176 => [ "SYDOR INSTRUMENTS, LLC", "Sydor Instruments, LLC" ], # Sydor Instruments
    178 => [ "XUV LASERS, INC.", "XUV Lasers, Inc." ], # XUV Lasers
  }.freeze

  def up
    CHANGES.each do |id, (old, new)|
      row = OrganizationAlias.find_by(id:)
      next say("Alias #{id} is already gone") if row.nil?
      next if row.alias == new
      raise "alias #{id} is #{row.alias.inspect}, not #{old.inspect}" unless row.alias == old

      row.update!(alias: new)
      say "Alias #{id} (#{row.organization.name}): #{old} -> #{new}"
    end
  end
end
