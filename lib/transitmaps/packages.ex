defmodule Transitmaps.Packages do
  @moduledoc """
  Hand-picked bundles of catalog agencies for a region, for visitors who
  want "the Bay Area" rather than knowing which operators run it.

  Every member is vetted: its download on MobilityData's mirror is under
  the import size limit (`Transitmaps.Agencies`) and its trips are drawn
  from route shapes. The mirror serves feeds whose own site needs an API
  key, and a pack vouches for those (and for operators the catalog has
  stopped tracking, such as Muni), so `Transitmaps.Catalog` offers a pack's
  members even when it wouldn't list them on its own.

  `bounds` is where the map flies to show the pack, not every member's
  reach: Amtrak alone spans the continent.

  National rail feeds that publish no shapes (Germany's, SNCF's, SNCB's,
  Switzerland's) are drawn from copies whose trains are traced along
  OpenStreetMap's railways (see `Transitmaps.Catalog`). Some obvious
  regions are still missing: SNCF Transilien's and Metrolink's shapes only
  join their stops with straight lines; Melbourne's feed nests one feed per mode in folders, which the
  importer doesn't read; Sydney, Brisbane and Tokyo's railways aren't in the
  catalog.
  """

  @packages [
    # -- North America ------------------------------------------------------
    %{
      id: "bay-area",
      region: "North America",
      label: "San Francisco Bay Area",
      place: "California, United States",
      keywords: "sf san francisco oakland san jose silicon valley marin",
      bounds: [[-122.8, 37.15], [-121.6, 38.15]],
      catalog_ids: [
        # BART, Caltrain, Muni, VTA
        "mdb-53",
        "mdb-54",
        "mdb-2886",
        "mdb-57",
        # AC Transit, SamTrans, Golden Gate Transit, SF Bay Ferry
        "mdb-2455",
        "mdb-2708",
        "mdb-67",
        "mdb-3143",
        # Capitol Corridor, ACE, SMART
        "mdb-74",
        "mdb-2684",
        "mdb-3222"
      ]
    },
    %{
      id: "southern-california",
      region: "North America",
      label: "Southern California",
      place: "Los Angeles to San Diego, United States",
      keywords: "la los angeles orange county anaheim santa monica long beach san diego",
      bounds: [[-118.9, 32.6], [-116.9, 34.35]],
      # Metrolink's feed has shapes but never links its trips to them.
      catalog_ids: [
        # LA Metro Rail, LA Metro Bus, Amtrak (Pacific Surfliner)
        "mdb-30",
        "mdb-29",
        "mdb-11",
        # OCTA, Big Blue Bus, Long Beach Transit, San Diego MTS
        "mdb-15",
        "mdb-37",
        "mdb-1198",
        "mdb-13"
      ]
    },
    %{
      id: "pacific-northwest",
      region: "North America",
      label: "Pacific Northwest",
      place: "Seattle, Portland and Vancouver",
      keywords: "seattle portland vancouver tacoma bellevue washington oregon british columbia",
      bounds: [[-123.4, 45.3], [-121.9, 49.4]],
      catalog_ids: [
        # Sound Transit, King County Metro, Community Transit, Seattle Monorail
        "mdb-268",
        "mdb-1330",
        "mdb-287",
        "tld-2290",
        # Washington State Ferries, TriMet, TransLink, BC Ferries, Amtrak (Cascades)
        "mdb-1331",
        "mdb-247",
        "mdb-696",
        "mdb-690",
        "mdb-11"
      ]
    },
    %{
      id: "chicago",
      region: "North America",
      label: "Chicagoland",
      place: "Chicago, United States",
      keywords: "chicago cta metra pace illinois indiana south shore",
      bounds: [[-88.4, 41.4], [-87.3, 42.3]],
      catalog_ids: [
        # CTA, Metra, Pace, South Shore Line, Chicago Water Taxi
        "mdb-389",
        "mdb-2854",
        "mdb-2347",
        "mdb-585",
        "mdb-306"
      ]
    },
    %{
      id: "northeast-corridor",
      region: "North America",
      label: "Northeast Corridor",
      place: "Boston to Washington, United States",
      keywords:
        "nec amtrak boston new york nyc philadelphia baltimore washington dc connecticut new jersey",
      bounds: [[-77.5, 38.6], [-70.8, 42.6]],
      catalog_ids: [
        # Amtrak, MBTA, CTrail Hartford Line, Metro-North, LIRR, NYC Subway
        "mdb-11",
        "mdb-437",
        "mdb-2840",
        "mdb-524",
        "mdb-507",
        "mdb-516",
        # NJ Transit Rail, SEPTA Regional Rail, SEPTA Metro, PATCO
        "mdb-509",
        "mdb-503",
        "mdb-502",
        "mdb-3035",
        # MARC, Baltimore Light Rail, Baltimore Metro, WMATA Metrorail, VRE
        "mdb-468",
        "mdb-469",
        "mdb-470",
        "mdb-1847",
        "tld-61"
      ]
    },
    %{
      id: "canada-corridor",
      region: "North America",
      label: "Toronto, Ottawa & Montréal",
      place: "Ontario and Québec, Canada",
      keywords:
        "toronto ttc go transit ottawa montreal quebec via rail mississauga brampton york",
      bounds: [[-80.2, 43.0], [-73.2, 45.9]],
      catalog_ids: [
        # TTC, GO Transit, UP Express, MiWay, Brampton Transit, York Region Transit
        "mdb-732",
        "mdb-1993",
        "mdb-1995",
        "mdb-730",
        "mdb-1994",
        "mdb-728",
        # OC Transpo, STM, exo trains, REM, VIA Rail
        "mdb-2154",
        "mdb-2126",
        "mdb-748",
        "tld-6691",
        "mdb-735"
      ]
    },
    # -- Europe -------------------------------------------------------------
    %{
      id: "france",
      region: "Europe",
      label: "France",
      place: "Paris and major cities",
      keywords: "paris lyon toulouse bordeaux nantes nice rennes montpellier eurostar",
      bounds: [[-4.9, 42.2], [8.4, 51.2]],
      catalog_ids: [
        # SNCF TGV, Intercités and TER (traced along OpenStreetMap)
        "tdg-83582",
        # Île-de-France Mobilités (Métro, RER, Transilien, tram, bus), Eurostar
        "tdg-80921",
        "tdg-82199",
        # TCL Lyon, Tisséo Toulouse, TBM Bordeaux, Naolib Nantes
        "tdg-81943",
        "tdg-81678",
        "tdg-83024",
        "tdg-84101",
        # Lignes d'Azur Nice, STAR Rennes, TaM Montpellier
        "tdg-83178",
        "tdg-83281",
        "tdg-83773"
      ]
    },
    %{
      id: "germany",
      region: "Europe",
      label: "Germany",
      place: "Deutsche Bahn, Berlin, Hamburg, Munich and Cologne",
      keywords:
        "deutschland germany db deutsche bahn ice intercity regional berlin brandenburg hamburg munich münchen cologne köln bonn",
      bounds: [[5.8, 47.3], [15.1, 55.0]],
      catalog_ids: [
        # Long-distance and regional rail (gtfs.de, traced along OpenStreetMap)
        "mdb-768",
        "mdb-1089",
        # VBB Berlin-Brandenburg, HVV Hamburg, MVG Munich, VRS Cologne/Bonn
        "mdb-782",
        "mdb-3362",
        "mdb-2333",
        "mdb-778",
        # European Sleeper
        "mdb-3107"
      ]
    },
    %{
      id: "iberia",
      region: "Europe",
      label: "Spain & Portugal",
      place: "Madrid, Barcelona, Lisbon and more",
      keywords:
        "españa spain portugal madrid barcelona catalunya lisbon lisboa valencia bilbao renfe cercanías",
      bounds: [[-9.6, 36.0], [3.4, 43.8]],
      catalog_ids: [
        # Metro de Madrid, Madrid Metro Ligero, Madrid city buses
        "mdb-794",
        "mdb-2802",
        "mdb-2820",
        # TMB, FGC, TRAM Barcelona (Trambaix, Trambesòs)
        "mdb-2359",
        "mdb-1856",
        "mdb-1003",
        "mdb-1004",
        # Renfe high-speed and long-distance trains (traced along OpenStreetMap),
        # Renfe Cercanías, Metrovalencia, Metro Bilbao
        "mdb-2620",
        "mdb-2653",
        "mdb-2830",
        "mdb-3052",
        # Metro de Lisboa, Carris, Fertagus, Transtejo Soflusa, Metro Sul do Tejo
        "tld-716",
        "mdb-2929",
        "tld-715",
        "mdb-2921",
        "mdb-2408"
      ]
    },
    %{
      id: "italy",
      region: "Europe",
      label: "Italian cities",
      place: "Milan, Rome, Turin, Naples and Venice",
      keywords:
        "italia italy milano milan roma rome torino turin napoli naples venezia venice bologna",
      bounds: [[6.6, 40.6], [16.0, 46.6]],
      catalog_ids: [
        # ATM Milan, Roma Mobilità, GTT Turin, ANM Naples, ACTV Venice ferries
        "mdb-2666",
        "mdb-1294",
        "mdb-2687",
        "tld-47",
        "mdb-1063",
        # Marconi Express Bologna
        "mdb-3041"
      ]
    },
    %{
      id: "benelux",
      region: "Europe",
      label: "Benelux",
      place: "The Netherlands and Belgium",
      keywords:
        "nederland netherlands holland amsterdam rotterdam utrecht den haag hague ns belgium belgië belgique brussels bruxelles brussel antwerp antwerpen ghent gent flanders wallonia liège",
      bounds: [[2.5, 49.5], [7.3, 53.6]],
      catalog_ids: [
        # SNCB (traced along OpenStreetMap)
        "mdb-1859",
        # OVapi (every Dutch operator, NS trains included), De Lijn, TEC, STIB
        "mdb-1077",
        "mdb-684",
        "mdb-1212",
        "mdb-1088"
      ]
    },
    %{
      id: "nordics",
      region: "Europe",
      label: "Nordic countries",
      place: "Denmark, Norway, Sweden and Finland",
      keywords:
        "nordic scandinavia denmark danmark copenhagen københavn norway norge oslo bergen trondheim sweden sverige stockholm gothenburg göteborg malmö skåne finland helsinki",
      bounds: [[4.5, 54.5], [25.5, 64.0]],
      catalog_ids: [
        # Rejseplanen (all of Denmark), Entur (all of Norway), all of Sweden
        "mdb-1292",
        "mdb-1078",
        "mdb-2939",
        # Finland's passenger trains
        "mdb-1102",
        # HSL Helsinki
        "mdb-865"
      ]
    },
    %{
      id: "switzerland",
      region: "Europe",
      label: "Switzerland",
      place: "SBB and every Swiss operator",
      keywords:
        "schweiz suisse svizzera swiss switzerland sbb cff ffs zürich zurich genève geneva basel bern lausanne luzern",
      bounds: [[5.9, 45.8], [10.5, 47.9]],
      catalog_ids: [
        # Switzerland's national feed (traced along OpenStreetMap)
        "mdb-2898"
      ]
    },
    %{
      id: "ireland",
      region: "Europe",
      label: "Ireland",
      place: "Dublin and nationwide",
      keywords: "éire ireland dublin cork galway limerick luas dart irish rail",
      bounds: [[-10.6, 51.4], [-5.9, 55.4]],
      catalog_ids: [
        # Irish Rail, Luas, Dublin Bus, Go-Ahead Ireland, Bus Éireann
        "mdb-2637",
        "mdb-2638",
        "mdb-2635",
        "mdb-2639",
        "mdb-2636"
      ]
    },
    %{
      id: "central-europe",
      region: "Europe",
      label: "Central Europe",
      place: "Prague, Vienna, Budapest, Warsaw, Kraków and Poland's trains",
      keywords:
        "praha prague wien vienna budapest warszawa warsaw kraków krakow czechia austria hungary poland polska pkp intercity",
      bounds: [[12.0, 46.9], [22.0, 53.0]],
      catalog_ids: [
        # PID Prague, Wiener Linien, BKK Budapest
        "mdb-767",
        "mdb-648",
        "mdb-990",
        # ZTM Warsaw, every Polish train operator (Koleje Mazowieckie
        # included), WKD, Kraków trams
        "mdb-2092",
        "mdb-3191",
        "mdb-2091",
        "mdb-1270"
      ]
    },
    # -- Oceania ------------------------------------------------------------
    %{
      id: "new-zealand",
      region: "Oceania",
      label: "New Zealand",
      place: "Auckland, Wellington, Christchurch and more",
      keywords: "aotearoa nz auckland wellington christchurch dunedin tauranga hamilton",
      bounds: [[166.4, -47.3], [178.6, -34.4]],
      catalog_ids: [
        # Auckland Transport, Metlink Wellington, Metro Christchurch
        "mdb-1029",
        "mdb-1132",
        "mdb-1313",
        # Orbus Dunedin, BayBus Tauranga, Busit Waikato
        "mdb-983",
        "mdb-1071",
        "tld-6738"
      ]
    },
    # -- Latin America ------------------------------------------------------
    %{
      id: "latin-america",
      region: "Latin America",
      label: "Latin American cities",
      place: "Mexico City, Bogotá, Santiago, São Paulo and Rio",
      keywords:
        "latam méxico mexico cdmx bogotá bogota colombia santiago chile são paulo sao paulo rio de janeiro belo horizonte brasil brazil",
      bounds: [[-100.0, -34.5], [-34.0, 20.5]],
      catalog_ids: [
        # Mexico City, Bogotá, Santiago (Red, Metro, EFE)
        "mdb-1830",
        "mdb-3358",
        "mdb-3357",
        # SPTrans São Paulo, Rio de Janeiro buses, BHTrans Belo Horizonte
        "mdb-8",
        "mdb-1791",
        "mdb-9"
      ]
    }
  ]

  @doc "Every pack, grouped by region in menu order."
  def all, do: @packages

  @doc "The pack with `id`, or nil."
  def get(id), do: Enum.find(@packages, &(&1.id == id))

  @doc "Packs whose name, place or keywords contain every word of `query`."
  def search(query) do
    words = query |> String.downcase() |> String.split(~r/\s+/, trim: true)

    Enum.filter(@packages, fn package ->
      text = String.downcase("#{package.label} #{package.place} #{package.keywords}")
      words != [] and Enum.all?(words, &String.contains?(text, &1))
    end)
  end

  @doc "Catalog ids of every pack's members."
  def catalog_ids, do: @packages |> Enum.flat_map(& &1.catalog_ids) |> MapSet.new()
end
