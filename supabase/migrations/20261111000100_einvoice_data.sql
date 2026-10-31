-- E-invoicing with the NRS Merchant Buyer Solution (MBS), part 2a: what every invoice sent to NRS needs, kept ready
-- before the first one goes.
--
--   * Places: NRS codes its states (NG-LA) and local government areas (NG-LA-IKE) itself, and spells some LGAs its own
--     way (Obia/Akpor for Obio/Akpor, Yenegoa for Yenagoa). Each of the 774 LGAs Counta keeps gets its NRS code, matched
--     by name against NRS's list of 31 October 2026 and by hand for the 43 NRS spells differently. NRS's list has two
--     more (Ibadan Central and Karawa), which are not local government areas.
--   * Addresses: a branch gets a city and a postcode, a customer a postcode, and a customer can be a government body (an
--     invoice to it is business-to-government).
--   * HS codes: each item gets the HS code NRS wants on its invoice lines, chosen by Gemini from NRS's list. Below the
--     business's confidence threshold the code is marked to confirm. A person can change it, and then Gemini leaves it.
--   * Each business's NRS settings: its Business ID and Service ID, and its API key, API secret and crypto_keys.txt, which
--     the einvoice function wraps with the Google Cloud HSM key (nrs-credentials) before they are stored. No one reads
--     them back: the app shows the last four characters. While NRS is in test mode, TaxStreem's admins can run a business
--     on TaxStreem's own provider keys; in production each business uses its own. The business also gets a service code
--     (ISIC, from NRS's list) for its service lines, chosen by Gemini and changeable by the owner.
--   * Readiness: what is still missing before the business can switch e-invoicing on.

-- ---------------------------------------------------------------------------
-- 1. Places
-- ---------------------------------------------------------------------------
alter table public.ng_lgas add column if not exists nrs_code text;
update public.ng_lgas l set nrs_code = v.code
from (values
  ('Abia', 'Aba North', 'NG-AB-ANO'), ('Abia', 'Aba South', 'NG-AB-ASO'), ('Abia', 'Arochukwu', 'NG-AB-ARO'), ('Abia', 'Bende', 'NG-AB-BEN'), ('Abia', 'Ikwuano', 'NG-AB-IKW'),
  ('Abia', 'Isiala Ngwa North', 'NG-AB-INN'), ('Abia', 'Isiala Ngwa South', 'NG-AB-INS'), ('Abia', 'Isuikwuato', 'NG-AB-ISU'), ('Abia', 'Obi Ngwa', 'NG-AB-ONW'), ('Abia', 'Ohafia', 'NG-AB-OHA'),
  ('Abia', 'Osisioma', 'NG-AB-ONG'), ('Abia', 'Ugwunagbo', 'NG-AB-UGW'), ('Abia', 'Ukwa East', 'NG-AB-UEA'), ('Abia', 'Ukwa West', 'NG-AB-UWE'), ('Abia', 'Umuahia North', 'NG-AB-UNO'),
  ('Abia', 'Umuahia South', 'NG-AB-USO'), ('Abia', 'Umu Nneochi', 'NG-AB-UNE'), ('Adamawa', 'Demsa', 'NG-AD-DEM'), ('Adamawa', 'Fufure', 'NG-AD-FUF'), ('Adamawa', 'Ganye', 'NG-AD-GAN'),
  ('Adamawa', 'Gayuk', 'NG-AD-GUY'), ('Adamawa', 'Gombi', 'NG-AD-GOM'), ('Adamawa', 'Grie', 'NG-AD-GIR'), ('Adamawa', 'Hong', 'NG-AD-HON'), ('Adamawa', 'Jada', 'NG-AD-JAD'),
  ('Adamawa', 'Lamurde', 'NG-AD-LAM'), ('Adamawa', 'Madagali', 'NG-AD-MAD'), ('Adamawa', 'Maiha', 'NG-AD-MAI'), ('Adamawa', 'Mayo Belwa', 'NG-AD-MBE'), ('Adamawa', 'Michika', 'NG-AD-MIC'),
  ('Adamawa', 'Mubi North', 'NG-AD-MNO'), ('Adamawa', 'Mubi South', 'NG-AD-MSO'), ('Adamawa', 'Numan', 'NG-AD-NUM'), ('Adamawa', 'Shelleng', 'NG-AD-SHE'), ('Adamawa', 'Song', 'NG-AD-SON'),
  ('Adamawa', 'Toungo', 'NG-AD-TOU'), ('Adamawa', 'Yola North', 'NG-AD-YNO'), ('Adamawa', 'Yola South', 'NG-AD-YSO'), ('Akwa Ibom', 'Abak', 'NG-AK-ABA'), ('Akwa Ibom', 'Eastern Obolo', 'NG-AK-EOB'),
  ('Akwa Ibom', 'Eket', 'NG-AK-EKE'), ('Akwa Ibom', 'Esit Eket', 'NG-AK-EEK'), ('Akwa Ibom', 'Essien Udim', 'NG-AK-EUD'), ('Akwa Ibom', 'Etim Ekpo', 'NG-AK-EE1'), ('Akwa Ibom', 'Etinan', 'NG-AK-ETI'),
  ('Akwa Ibom', 'Ibeno', 'NG-AK-IBE'), ('Akwa Ibom', 'Ibesikpo Asutan', 'NG-AK-IAS'), ('Akwa Ibom', 'Ibiono-Ibom', 'NG-AK-IIB'), ('Akwa Ibom', 'Ika', 'NG-AK-IKA'), ('Akwa Ibom', 'Ikono', 'NG-AK-IKO'),
  ('Akwa Ibom', 'Ikot Abasi', 'NG-AK-IAB'), ('Akwa Ibom', 'Ikot Ekpene', 'NG-AK-IEK'), ('Akwa Ibom', 'Ini', 'NG-AK-INI'), ('Akwa Ibom', 'Itu', 'NG-AK-ITU'), ('Akwa Ibom', 'Mbo', 'NG-AK-MBO'),
  ('Akwa Ibom', 'Mkpat-Enin', 'NG-AK-MEN'), ('Akwa Ibom', 'Nsit-Atai', 'NG-AK-NAT'), ('Akwa Ibom', 'Nsit-Ibom', 'NG-AK-NIB'), ('Akwa Ibom', 'Nsit-Ubium', 'NG-AK-NUB'), ('Akwa Ibom', 'Obot Akara', 'NG-AK-OAK'),
  ('Akwa Ibom', 'Okobo', 'NG-AK-OKO'), ('Akwa Ibom', 'Onna', 'NG-AK-ONN'), ('Akwa Ibom', 'Oron', 'NG-AK-ORO'), ('Akwa Ibom', 'Oruk Anam', 'NG-AK-OAN'), ('Akwa Ibom', 'Udung-Uko', 'NG-AK-UUK'),
  ('Akwa Ibom', 'Ukanafun', 'NG-AK-UKA'), ('Akwa Ibom', 'Uruan', 'NG-AK-URU'), ('Akwa Ibom', 'Urue-Offong/Oruko', 'NG-AK-UOF'), ('Akwa Ibom', 'Uyo', 'NG-AK-UYO'), ('Anambra', 'Aguata', 'NG-AN-AGU'),
  ('Anambra', 'Anambra East', 'NG-AN-AEA'), ('Anambra', 'Anambra West', 'NG-AN-AWE'), ('Anambra', 'Anaocha', 'NG-AN-ANA'), ('Anambra', 'Awka North', 'NG-AN-ANO'), ('Anambra', 'Awka South', 'NG-AN-ASO'),
  ('Anambra', 'Ayamelum', 'NG-AN-AYA'), ('Anambra', 'Dunukofia', 'NG-AN-DUN'), ('Anambra', 'Ekwusigo', 'NG-AN-EKW'), ('Anambra', 'Idemili North', 'NG-AN-INO'), ('Anambra', 'Idemili South', 'NG-AN-ISO'),
  ('Anambra', 'Ihiala', 'NG-AN-IHI'), ('Anambra', 'Njikoka', 'NG-AN-NJI'), ('Anambra', 'Nnewi North', 'NG-AN-NNO'), ('Anambra', 'Nnewi South', 'NG-AN-NSO'), ('Anambra', 'Ogbaru', 'NG-AN-OGB'),
  ('Anambra', 'Onitsha North', 'NG-AN-ONO'), ('Anambra', 'Onitsha South', 'NG-AN-OSO'), ('Anambra', 'Orumba North', 'NG-AN-ON1'), ('Anambra', 'Orumba South', 'NG-AN-OS1'), ('Anambra', 'Oyi', 'NG-AN-OYI'),
  ('Bauchi', 'Alkaleri', 'NG-BA-ALK'), ('Bauchi', 'Bauchi', 'NG-BA-BAU'), ('Bauchi', 'Bogoro', 'NG-BA-BOG'), ('Bauchi', 'Damban', 'NG-BA-DAM'), ('Bauchi', 'Darazo', 'NG-BA-DAR'),
  ('Bauchi', 'Dass', 'NG-BA-DAS'), ('Bauchi', 'Gamawa', 'NG-BA-GLG'), ('Bauchi', 'Ganjuwa', 'NG-BA-GAN'), ('Bauchi', 'Giade', 'NG-BA-GIA'), ('Bauchi', 'Itas/Gadau', 'NG-BA-ITA'),
  ('Bauchi', 'Jama''are', 'NG-BA-JAM'), ('Bauchi', 'Katagum', 'NG-BA-KAT'), ('Bauchi', 'Kirfi', 'NG-BA-KIR'), ('Bauchi', 'Misau', 'NG-BA-MIS'), ('Bauchi', 'Ningi', 'NG-BA-NIN'),
  ('Bauchi', 'Shira', 'NG-BA-SHI'), ('Bauchi', 'Tafawa Balewa', 'NG-BA-TBA'), ('Bauchi', 'Toro', 'NG-BA-TOR'), ('Bauchi', 'Warji', 'NG-BA-WAR'), ('Bauchi', 'Zaki', 'NG-BA-ZAK'),
  ('Bayelsa', 'Brass', 'NG-BY-BRA'), ('Bayelsa', 'Ekeremor', 'NG-BY-EKE'), ('Bayelsa', 'Kolokuma/Opokuma', 'NG-BY-KOL'), ('Bayelsa', 'Nembe', 'NG-BY-NEM'), ('Bayelsa', 'Ogbia', 'NG-BY-OGB'),
  ('Bayelsa', 'Sagbama', 'NG-BY-SAG'), ('Bayelsa', 'Southern Ijaw', 'NG-BY-SIJ'), ('Bayelsa', 'Yenagoa', 'NG-BY-YEN'), ('Benue', 'Agatu', 'NG-BE-AGA'), ('Benue', 'Apa', 'NG-BE-APA'),
  ('Benue', 'Ado', 'NG-BE-ADO'), ('Benue', 'Buruku', 'NG-BE-BUR'), ('Benue', 'Gboko', 'NG-BE-GBO'), ('Benue', 'Guma', 'NG-BE-GUM'), ('Benue', 'Gwer East', 'NG-BE-GEA'),
  ('Benue', 'Gwer West', 'NG-BE-GWE'), ('Benue', 'Katsina-Ala', 'NG-BE-KAL'), ('Benue', 'Konshisha', 'NG-BE-KON'), ('Benue', 'Kwande', 'NG-BE-KWA'), ('Benue', 'Logo', 'NG-BE-LOG'),
  ('Benue', 'Makurdi', 'NG-BE-MAK'), ('Benue', 'Obi', 'NG-BE-OBI'), ('Benue', 'Ogbadibo', 'NG-BE-OGB'), ('Benue', 'Ohimini', 'NG-BE-OHI'), ('Benue', 'Oju', 'NG-BE-OJU'),
  ('Benue', 'Okpokwu', 'NG-BE-OKP'), ('Benue', 'Oturkpo', 'NG-BE-OTU'), ('Benue', 'Tarka', 'NG-BE-TAR'), ('Benue', 'Ukum', 'NG-BE-UKU'), ('Benue', 'Ushongo', 'NG-BE-USH'),
  ('Benue', 'Vandeikya', 'NG-BE-VAN'), ('Borno', 'Abadam', 'NG-BO-ABA'), ('Borno', 'Askira/Uba', 'NG-BO-ASK'), ('Borno', 'Bama', 'NG-BO-BAM'), ('Borno', 'Bayo', 'NG-BO-BAY'),
  ('Borno', 'Biu', 'NG-BO-BIU'), ('Borno', 'Chibok', 'NG-BO-CHI'), ('Borno', 'Damboa', 'NG-BO-DAM'), ('Borno', 'Dikwa', 'NG-BO-DIK'), ('Borno', 'Gubio', 'NG-BO-GUB'),
  ('Borno', 'Guzamala', 'NG-BO-GUZ'), ('Borno', 'Gwoza', 'NG-BO-GWO'), ('Borno', 'Hawul', 'NG-BO-HAW'), ('Borno', 'Jere', 'NG-BO-JER'), ('Borno', 'Kaga', 'NG-BO-KAG'),
  ('Borno', 'Kala/Balge', 'NG-BO-KAL'), ('Borno', 'Konduga', 'NG-BO-KON'), ('Borno', 'Kukawa', 'NG-BO-KUK'), ('Borno', 'Kwaya Kusar', 'NG-BO-KKU'), ('Borno', 'Mafa', 'NG-BO-MAF'),
  ('Borno', 'Magumeri', 'NG-BO-MAG'), ('Borno', 'Maiduguri', 'NG-BO-MAI'), ('Borno', 'Marte', 'NG-BO-MAR'), ('Borno', 'Mobbar', 'NG-BO-MOB'), ('Borno', 'Monguno', 'NG-BO-MON'),
  ('Borno', 'Ngala', 'NG-BO-NGA'), ('Borno', 'Nganzai', 'NG-BO-NG1'), ('Borno', 'Shani', 'NG-BO-SHA'), ('Cross River', 'Abi', 'NG-CR-ABI'), ('Cross River', 'Akamkpa', 'NG-CR-AKA'),
  ('Cross River', 'Akpabuyo', 'NG-CR-AKP'), ('Cross River', 'Bakassi', 'NG-CR-BAK'), ('Cross River', 'Bekwarra', 'NG-CR-BEK'), ('Cross River', 'Biase', 'NG-CR-BIA'), ('Cross River', 'Boki', 'NG-CR-BOK'),
  ('Cross River', 'Calabar Municipal', 'NG-CR-CMU'), ('Cross River', 'Calabar South', 'NG-CR-CSO'), ('Cross River', 'Etung', 'NG-CR-ETU'), ('Cross River', 'Ikom', 'NG-CR-IKO'), ('Cross River', 'Obanliku', 'NG-CR-OBA'),
  ('Cross River', 'Obubra', 'NG-CR-OBU'), ('Cross River', 'Obudu', 'NG-CR-OB1'), ('Cross River', 'Odukpani', 'NG-CR-ODU'), ('Cross River', 'Ogoja', 'NG-CR-OGO'), ('Cross River', 'Yakuur', 'NG-CR-YAK'),
  ('Cross River', 'Yala', 'NG-CR-YAL'), ('Delta', 'Aniocha North', 'NG-DE-ANO'), ('Delta', 'Aniocha South', 'NG-DE-ASO'), ('Delta', 'Bomadi', 'NG-DE-BOM'), ('Delta', 'Burutu', 'NG-DE-BUR'),
  ('Delta', 'Ethiope East', 'NG-DE-EEA'), ('Delta', 'Ethiope West', 'NG-DE-EWE'), ('Delta', 'Ika North East', 'NG-DE-INE'), ('Delta', 'Ika South', 'NG-DE-ISO'), ('Delta', 'Isoko North', 'NG-DE-INO'),
  ('Delta', 'Isoko South', 'NG-DE-IS1'), ('Delta', 'Ndokwa East', 'NG-DE-NEA'), ('Delta', 'Ndokwa West', 'NG-DE-NWE'), ('Delta', 'Okpe', 'NG-DE-OKP'), ('Delta', 'Oshimili North', 'NG-DE-ONO'),
  ('Delta', 'Oshimili South', 'NG-DE-OSO'), ('Delta', 'Patani', 'NG-DE-PAT'), ('Delta', 'Sapele', 'NG-DE-SAP'), ('Delta', 'Udu', 'NG-DE-UDU'), ('Delta', 'Ughelli North', 'NG-DE-UNO'),
  ('Delta', 'Ughelli South', 'NG-DE-USO'), ('Delta', 'Ukwuani', 'NG-DE-UKW'), ('Delta', 'Uvwie', 'NG-DE-UVW'), ('Delta', 'Warri North', 'NG-DE-WNO'), ('Delta', 'Warri South', 'NG-DE-WSO'),
  ('Delta', 'Warri South West', 'NG-DE-WSW'), ('Ebonyi', 'Abakaliki', 'NG-EB-ABA'), ('Ebonyi', 'Afikpo North', 'NG-EB-ANO'), ('Ebonyi', 'Afikpo South', 'NG-EB-ASO'), ('Ebonyi', 'Ebonyi', 'NG-EB-EBO'),
  ('Ebonyi', 'Ezza North', 'NG-EB-ENO'), ('Ebonyi', 'Ezza South', 'NG-EB-ESO'), ('Ebonyi', 'Ikwo', 'NG-EB-IKW'), ('Ebonyi', 'Ishielu', 'NG-EB-ISH'), ('Ebonyi', 'Ivo', 'NG-EB-IVO'),
  ('Ebonyi', 'Izzi', 'NG-EB-IZZ'), ('Ebonyi', 'Ohaozara', 'NG-EB-OHA'), ('Ebonyi', 'Ohaukwu', 'NG-EB-OH1'), ('Ebonyi', 'Onicha', 'NG-EB-ONI'), ('Edo', 'Akoko-Edo', 'NG-ED-AED'),
  ('Edo', 'Egor', 'NG-ED-EGO'), ('Edo', 'Esan Central', 'NG-ED-ECE'), ('Edo', 'Esan North-East', 'NG-ED-ENE'), ('Edo', 'Esan South-East', 'NG-ED-ESE'), ('Edo', 'Esan West', 'NG-ED-EWE'),
  ('Edo', 'Etsako Central', 'NG-ED-EC1'), ('Edo', 'Etsako East', 'NG-ED-EEA'), ('Edo', 'Etsako West', 'NG-ED-EW1'), ('Edo', 'Igueben', 'NG-ED-IGU'), ('Edo', 'Ikpoba Okha', 'NG-ED-IOK'),
  ('Edo', 'Orhionmwon', 'NG-ED-ORH'), ('Edo', 'Oredo', 'NG-ED-ORE'), ('Edo', 'Ovia North-East', 'NG-ED-ONE'), ('Edo', 'Ovia South-West', 'NG-ED-OSW'), ('Edo', 'Owan East', 'NG-ED-OEA'),
  ('Edo', 'Owan West', 'NG-ED-OWE'), ('Edo', 'Uhunmwonde', 'NG-ED-UHU'), ('Ekiti', 'Ado Ekiti', 'NG-EK-ADO'), ('Ekiti', 'Efon', 'NG-EK-EFO'), ('Ekiti', 'Ekiti East', 'NG-EK-EEA'),
  ('Ekiti', 'Ekiti South-West', 'NG-EK-ESW'), ('Ekiti', 'Ekiti West', 'NG-EK-EWE'), ('Ekiti', 'Emure', 'NG-EK-EMU'), ('Ekiti', 'Gbonyin', 'NG-EK-AIY'), ('Ekiti', 'Ido Osi', 'NG-EK-IOS'),
  ('Ekiti', 'Ijero', 'NG-EK-IJE'), ('Ekiti', 'Ikere', 'NG-EK-IKE'), ('Ekiti', 'Ikole', 'NG-EK-IKO'), ('Ekiti', 'Ilejemeje', 'NG-EK-ILE'), ('Ekiti', 'Irepodun/Ifelodun', 'NG-EK-IRE'),
  ('Ekiti', 'Ise/Orun', 'NG-EK-ISE'), ('Ekiti', 'Moba', 'NG-EK-MOB'), ('Ekiti', 'Oye', 'NG-EK-OYE'), ('Enugu', 'Aninri', 'NG-EN-ANI'), ('Enugu', 'Awgu', 'NG-EN-AWG'),
  ('Enugu', 'Enugu East', 'NG-EN-EEA'), ('Enugu', 'Enugu North', 'NG-EN-ENO'), ('Enugu', 'Enugu South', 'NG-EN-ESO'), ('Enugu', 'Ezeagu', 'NG-EN-EZE'), ('Enugu', 'Igbo Etiti', 'NG-EN-IET'),
  ('Enugu', 'Igbo Eze North', 'NG-EN-IEN'), ('Enugu', 'Igbo Eze South', 'NG-EN-IES'), ('Enugu', 'Isi Uzo', 'NG-EN-IUZ'), ('Enugu', 'Nkanu East', 'NG-EN-NEA'), ('Enugu', 'Nkanu West', 'NG-EN-NWE'),
  ('Enugu', 'Nsukka', 'NG-EN-NSU'), ('Enugu', 'Oji River', 'NG-EN-ORI'), ('Enugu', 'Udenu', 'NG-EN-UDE'), ('Enugu', 'Udi', 'NG-EN-UDI'), ('Enugu', 'Uzo Uwani', 'NG-EN-UUW'),
  ('FCT', 'Abaji', 'NG-FC-ALG'), ('FCT', 'Bwari', 'NG-FC-BLG'), ('FCT', 'Gwagwalada', 'NG-FC-GLG'), ('FCT', 'Kuje', 'NG-FC-KLG'), ('FCT', 'Kwali', 'NG-FC-KL1'),
  ('FCT', 'Municipal Area Council', 'NG-FC-AML'), ('Gombe', 'Akko', 'NG-GO-AKK'), ('Gombe', 'Balanga', 'NG-GO-BAL'), ('Gombe', 'Billiri', 'NG-GO-BIL'), ('Gombe', 'Dukku', 'NG-GO-DUK'),
  ('Gombe', 'Funakaye', 'NG-GO-FUN'), ('Gombe', 'Gombe', 'NG-GO-GOM'), ('Gombe', 'Kaltungo', 'NG-GO-KAL'), ('Gombe', 'Kwami', 'NG-GO-KWA'), ('Gombe', 'Nafada', 'NG-GO-NAF'),
  ('Gombe', 'Shongom', 'NG-GO-SHO'), ('Gombe', 'Yamaltu/Deba', 'NG-GO-YAM'), ('Imo', 'Aboh Mbaise', 'NG-IM-AMB'), ('Imo', 'Ahiazu Mbaise', 'NG-IM-AM1'), ('Imo', 'Ehime Mbano', 'NG-IM-EMB'),
  ('Imo', 'Ezinihitte', 'NG-IM-EZI'), ('Imo', 'Ideato North', 'NG-IM-INO'), ('Imo', 'Ideato South', 'NG-IM-ISO'), ('Imo', 'Ihitte/Uboma', 'NG-IM-IHI'), ('Imo', 'Ikeduru', 'NG-IM-IKE'),
  ('Imo', 'Isiala Mbano', 'NG-IM-IMB'), ('Imo', 'Isu', 'NG-IM-ISU'), ('Imo', 'Mbaitoli', 'NG-IM-MBA'), ('Imo', 'Ngor Okpala', 'NG-IM-NOK'), ('Imo', 'Njaba', 'NG-IM-NJA'),
  ('Imo', 'Nkwerre', 'NG-IM-NKW'), ('Imo', 'Nwangele', 'NG-IM-NWA'), ('Imo', 'Obowo', 'NG-IM-OBO'), ('Imo', 'Oguta', 'NG-IM-OGU'), ('Imo', 'Ohaji/Egbema', 'NG-IM-OHA'),
  ('Imo', 'Okigwe', 'NG-IM-OKI'), ('Imo', 'Orlu', 'NG-IM-ORL'), ('Imo', 'Orsu', 'NG-IM-ORS'), ('Imo', 'Oru East', 'NG-IM-OEA'), ('Imo', 'Oru West', 'NG-IM-OWE'),
  ('Imo', 'Owerri Municipal', 'NG-IM-OMU'), ('Imo', 'Owerri North', 'NG-IM-ONO'), ('Imo', 'Owerri West', 'NG-IM-OW1'), ('Imo', 'Unuimo', 'NG-IM-UNU'), ('Jigawa', 'Auyo', 'NG-JI-AUY'),
  ('Jigawa', 'Babura', 'NG-JI-BAB'), ('Jigawa', 'Biriniwa', 'NG-JI-BIR'), ('Jigawa', 'Birnin Kudu', 'NG-JI-BKU'), ('Jigawa', 'Buji', 'NG-JI-BUJ'), ('Jigawa', 'Dutse', 'NG-JI-DUT'),
  ('Jigawa', 'Gagarawa', 'NG-JI-GAG'), ('Jigawa', 'Garki', 'NG-JI-GAR'), ('Jigawa', 'Gumel', 'NG-JI-GUM'), ('Jigawa', 'Guri', 'NG-JI-GUR'), ('Jigawa', 'Gwaram', 'NG-JI-GWA'),
  ('Jigawa', 'Gwiwa', 'NG-JI-GWI'), ('Jigawa', 'Hadejia', 'NG-JI-HAD'), ('Jigawa', 'Jahun', 'NG-JI-JAH'), ('Jigawa', 'Kafin Hausa', 'NG-JI-KHA'), ('Jigawa', 'Kazaure', 'NG-JI-KAZ'),
  ('Jigawa', 'Kiri Kasama', 'NG-JI-KKA'), ('Jigawa', 'Kiyawa', 'NG-JI-KIY'), ('Jigawa', 'Kaugama', 'NG-JI-KAU'), ('Jigawa', 'Maigatari', 'NG-JI-MAI'), ('Jigawa', 'Malam Madori', 'NG-JI-MMA'),
  ('Jigawa', 'Miga', 'NG-JI-MIG'), ('Jigawa', 'Ringim', 'NG-JI-RIN'), ('Jigawa', 'Roni', 'NG-JI-RON'), ('Jigawa', 'Sule Tankarkar', 'NG-JI-STA'), ('Jigawa', 'Taura', 'NG-JI-TAU'),
  ('Jigawa', 'Yankwashi', 'NG-JI-YAN'), ('Kaduna', 'Birnin Gwari', 'NG-KD-BGW'), ('Kaduna', 'Chikun', 'NG-KD-CHI'), ('Kaduna', 'Giwa', 'NG-KD-GIW'), ('Kaduna', 'Igabi', 'NG-KD-IGA'),
  ('Kaduna', 'Ikara', 'NG-KD-IKA'), ('Kaduna', 'Jaba', 'NG-KD-JAB'), ('Kaduna', 'Jema''a', 'NG-KD-JEM'), ('Kaduna', 'Kachia', 'NG-KD-KAC'), ('Kaduna', 'Kaduna North', 'NG-KD-KNO'),
  ('Kaduna', 'Kaduna South', 'NG-KD-KSO'), ('Kaduna', 'Kagarko', 'NG-KD-KAG'), ('Kaduna', 'Kajuru', 'NG-KD-KAJ'), ('Kaduna', 'Kaura', 'NG-KD-KLG'), ('Kaduna', 'Kauru', 'NG-KD-KAU'),
  ('Kaduna', 'Kubau', 'NG-KD-KUB'), ('Kaduna', 'Kudan', 'NG-KD-KUD'), ('Kaduna', 'Lere', 'NG-KD-LER'), ('Kaduna', 'Makarfi', 'NG-KD-MAR'), ('Kaduna', 'Sabon Gari', 'NG-KD-SGA'),
  ('Kaduna', 'Sanga', 'NG-KD-SAN'), ('Kaduna', 'Soba', 'NG-KD-SOB'), ('Kaduna', 'Zangon Kataf', 'NG-KD-ZKA'), ('Kaduna', 'Zaria', 'NG-KD-ZAR'), ('Kano', 'Ajingi', 'NG-KN-AJI'),
  ('Kano', 'Albasu', 'NG-KN-ALB'), ('Kano', 'Bagwai', 'NG-KN-BAG'), ('Kano', 'Bebeji', 'NG-KN-BEB'), ('Kano', 'Bichi', 'NG-KN-BIC'), ('Kano', 'Bunkure', 'NG-KN-BUN'),
  ('Kano', 'Dala', 'NG-KN-DAL'), ('Kano', 'Dambatta', 'NG-KN-DAM'), ('Kano', 'Dawakin Kudu', 'NG-KN-DKU'), ('Kano', 'Dawakin Tofa', 'NG-KN-DTO'), ('Kano', 'Doguwa', 'NG-KN-DOG'),
  ('Kano', 'Fagge', 'NG-KN-FAG'), ('Kano', 'Gabasawa', 'NG-KN-GAB'), ('Kano', 'Garko', 'NG-KN-GAR'), ('Kano', 'Garun Mallam', 'NG-KN-GMA'), ('Kano', 'Gaya', 'NG-KN-GAY'),
  ('Kano', 'Gezawa', 'NG-KN-GEZ'), ('Kano', 'Gwale', 'NG-KN-GWA'), ('Kano', 'Gwarzo', 'NG-KN-GW1'), ('Kano', 'Kabo', 'NG-KN-KAB'), ('Kano', 'Kano Municipal', 'NG-KN-KMU'),
  ('Kano', 'Karaye', 'NG-KN-KAR'), ('Kano', 'Kibiya', 'NG-KN-KIB'), ('Kano', 'Kiru', 'NG-KN-KIR'), ('Kano', 'Kumbotso', 'NG-KN-KUM'), ('Kano', 'Kunchi', 'NG-KN-KUN'),
  ('Kano', 'Kura', 'NG-KN-KUR'), ('Kano', 'Madobi', 'NG-KN-MAD'), ('Kano', 'Makoda', 'NG-KN-MAK'), ('Kano', 'Minjibir', 'NG-KN-MIN'), ('Kano', 'Nasarawa', 'NG-KN-NAS'),
  ('Kano', 'Rano', 'NG-KN-RAN'), ('Kano', 'Rimin Gado', 'NG-KN-RGA'), ('Kano', 'Rogo', 'NG-KN-ROG'), ('Kano', 'Shanono', 'NG-KN-SHA'), ('Kano', 'Sumaila', 'NG-KN-SUM'),
  ('Kano', 'Takai', 'NG-KN-TAK'), ('Kano', 'Tarauni', 'NG-KN-TAR'), ('Kano', 'Tofa', 'NG-KN-TOF'), ('Kano', 'Tsanyawa', 'NG-KN-TSA'), ('Kano', 'Tudun Wada', 'NG-KN-TWA'),
  ('Kano', 'Ungogo', 'NG-KN-UNG'), ('Kano', 'Warawa', 'NG-KN-WAR'), ('Kano', 'Wudil', 'NG-KN-WUD'), ('Katsina', 'Bakori', 'NG-KT-BAK'), ('Katsina', 'Batagarawa', 'NG-KT-BAT'),
  ('Katsina', 'Batsari', 'NG-KT-BA1'), ('Katsina', 'Baure', 'NG-KT-BAU'), ('Katsina', 'Bindawa', 'NG-KT-BIN'), ('Katsina', 'Charanchi', 'NG-KT-CHA'), ('Katsina', 'Dandume', 'NG-KT-DAN'),
  ('Katsina', 'Danja', 'NG-KT-DA1'), ('Katsina', 'Dan Musa', 'NG-KT-DMU'), ('Katsina', 'Daura', 'NG-KT-DAU'), ('Katsina', 'Dutsi', 'NG-KT-DUT'), ('Katsina', 'Dutsin Ma', 'NG-KT-DMA'),
  ('Katsina', 'Faskari', 'NG-KT-FAS'), ('Katsina', 'Funtua', 'NG-KT-FUN'), ('Katsina', 'Ingawa', 'NG-KT-ING'), ('Katsina', 'Jibia', 'NG-KT-JIB'), ('Katsina', 'Kafur', 'NG-KT-KAF'),
  ('Katsina', 'Kaita', 'NG-KT-KAI'), ('Katsina', 'Kankara', 'NG-KT-KAN'), ('Katsina', 'Kankia', 'NG-KT-KA1'), ('Katsina', 'Katsina', 'NG-KT-KAT'), ('Katsina', 'Kurfi', 'NG-KT-KUR'),
  ('Katsina', 'Kusada', 'NG-KT-KUS'), ('Katsina', 'Mai''Adua', 'NG-KT-MAI'), ('Katsina', 'Malumfashi', 'NG-KT-MAL'), ('Katsina', 'Mani', 'NG-KT-MAN'), ('Katsina', 'Mashi', 'NG-KT-MAS'),
  ('Katsina', 'Matazu', 'NG-KT-MAT'), ('Katsina', 'Musawa', 'NG-KT-MUS'), ('Katsina', 'Rimi', 'NG-KT-RIM'), ('Katsina', 'Sabuwa', 'NG-KT-SAB'), ('Katsina', 'Safana', 'NG-KT-SAF'),
  ('Katsina', 'Sandamu', 'NG-KT-SAN'), ('Katsina', 'Zango', 'NG-KT-ZAN'), ('Kebbi', 'Aleiro', 'NG-KE-ALE'), ('Kebbi', 'Arewa Dandi', 'NG-KE-ADA'), ('Kebbi', 'Argungu', 'NG-KE-ARG'),
  ('Kebbi', 'Augie', 'NG-KE-AUG'), ('Kebbi', 'Bagudo', 'NG-KE-BAG'), ('Kebbi', 'Birnin Kebbi', 'NG-KE-BKE'), ('Kebbi', 'Bunza', 'NG-KE-BUN'), ('Kebbi', 'Dandi', 'NG-KE-DAN'),
  ('Kebbi', 'Fakai', 'NG-KE-FAK'), ('Kebbi', 'Gwandu', 'NG-KE-GWA'), ('Kebbi', 'Jega', 'NG-KE-JEG'), ('Kebbi', 'Kalgo', 'NG-KE-KAL'), ('Kebbi', 'Koko/Besse', 'NG-KE-KOK'),
  ('Kebbi', 'Maiyama', 'NG-KE-MAI'), ('Kebbi', 'Ngaski', 'NG-KE-NGA'), ('Kebbi', 'Sakaba', 'NG-KE-SAK'), ('Kebbi', 'Shanga', 'NG-KE-SHA'), ('Kebbi', 'Suru', 'NG-KE-SUR'),
  ('Kebbi', 'Wasagu/Danko', 'NG-KE-WAS'), ('Kebbi', 'Yauri', 'NG-KE-YAU'), ('Kebbi', 'Zuru', 'NG-KE-ZUR'), ('Kogi', 'Adavi', 'NG-KO-ADA'), ('Kogi', 'Ajaokuta', 'NG-KO-AJA'),
  ('Kogi', 'Ankpa', 'NG-KO-ANK'), ('Kogi', 'Bassa', 'NG-KO-BAS'), ('Kogi', 'Dekina', 'NG-KO-DEK'), ('Kogi', 'Ibaji', 'NG-KO-IBA'), ('Kogi', 'Idah', 'NG-KO-IDA'),
  ('Kogi', 'Igalamela Odolu', 'NG-KO-IOD'), ('Kogi', 'Ijumu', 'NG-KO-IJU'), ('Kogi', 'Kabba/Bunu', 'NG-KO-KAB'), ('Kogi', 'Kogi', 'NG-KO-KOG'), ('Kogi', 'Lokoja', 'NG-KO-LOK'),
  ('Kogi', 'Mopa Muro', 'NG-KO-MMU'), ('Kogi', 'Ofu', 'NG-KO-OFU'), ('Kogi', 'Ogori/Magongo', 'NG-KO-OGO'), ('Kogi', 'Okehi', 'NG-KO-OKE'), ('Kogi', 'Okene', 'NG-KO-OK1'),
  ('Kogi', 'Olamaboro', 'NG-KO-OLA'), ('Kogi', 'Omala', 'NG-KO-OMA'), ('Kogi', 'Yagba East', 'NG-KO-YEA'), ('Kogi', 'Yagba West', 'NG-KO-YWE'), ('Kwara', 'Asa', 'NG-KW-ASA'),
  ('Kwara', 'Baruten', 'NG-KW-BAR'), ('Kwara', 'Edu', 'NG-KW-EDU'), ('Kwara', 'Ekiti', 'NG-KW-EKI'), ('Kwara', 'Ifelodun', 'NG-KW-IFE'), ('Kwara', 'Ilorin East', 'NG-KW-IEA'),
  ('Kwara', 'Ilorin South', 'NG-KW-ISL'), ('Kwara', 'Ilorin West', 'NG-KW-IWE'), ('Kwara', 'Irepodun', 'NG-KW-IRE'), ('Kwara', 'Isin', 'NG-KW-ISI'), ('Kwara', 'Kaiama', 'NG-KW-KAI'),
  ('Kwara', 'Moro', 'NG-KW-MOR'), ('Kwara', 'Offa', 'NG-KW-OFF'), ('Kwara', 'Oke Ero', 'NG-KW-OER'), ('Kwara', 'Oyun', 'NG-KW-OYU'), ('Kwara', 'Pategi', 'NG-KW-PAT'),
  ('Lagos', 'Agege', 'NG-LA-AGE'), ('Lagos', 'Ajeromi-Ifelodun', 'NG-LA-AIF'), ('Lagos', 'Alimosho', 'NG-LA-ALI'), ('Lagos', 'Amuwo-Odofin', 'NG-LA-AOD'), ('Lagos', 'Apapa', 'NG-LA-APA'),
  ('Lagos', 'Badagry', 'NG-LA-BAD'), ('Lagos', 'Epe', 'NG-LA-EPE'), ('Lagos', 'Eti Osa', 'NG-LA-EOS'), ('Lagos', 'Ibeju-Lekki', 'NG-LA-IBE'), ('Lagos', 'Ifako-Ijaiye', 'NG-LA-IIJ'),
  ('Lagos', 'Ikeja', 'NG-LA-IKE'), ('Lagos', 'Ikorodu', 'NG-LA-IKO'), ('Lagos', 'Kosofe', 'NG-LA-KOS'), ('Lagos', 'Lagos Island', 'NG-LA-LIS'), ('Lagos', 'Lagos Mainland', 'NG-LA-LMA'),
  ('Lagos', 'Mushin', 'NG-LA-MUS'), ('Lagos', 'Ojo', 'NG-LA-OJO'), ('Lagos', 'Oshodi-Isolo', 'NG-LA-OIS'), ('Lagos', 'Shomolu', 'NG-LA-SHO'), ('Lagos', 'Surulere', 'NG-LA-SUR'),
  ('Nasarawa', 'Akwanga', 'NG-NA-AKW'), ('Nasarawa', 'Awe', 'NG-NA-AWE'), ('Nasarawa', 'Doma', 'NG-NA-DOM'), ('Nasarawa', 'Karu', 'NG-NA-KAR'), ('Nasarawa', 'Keana', 'NG-NA-KEA'),
  ('Nasarawa', 'Keffi', 'NG-NA-KEF'), ('Nasarawa', 'Kokona', 'NG-NA-KOK'), ('Nasarawa', 'Lafia', 'NG-NA-LAF'), ('Nasarawa', 'Nasarawa', 'NG-NA-NAS'), ('Nasarawa', 'Nasarawa Egon', 'NG-NA-NEG'),
  ('Nasarawa', 'Obi', 'NG-NA-OBI'), ('Nasarawa', 'Toto', 'NG-NA-TOT'), ('Nasarawa', 'Wamba', 'NG-NA-WAM'), ('Niger', 'Agaie', 'NG-NI-AGA'), ('Niger', 'Agwara', 'NG-NI-AGW'),
  ('Niger', 'Bida', 'NG-NI-BID'), ('Niger', 'Borgu', 'NG-NI-BOR'), ('Niger', 'Bosso', 'NG-NI-BOS'), ('Niger', 'Chanchaga', 'NG-NI-CHA'), ('Niger', 'Edati', 'NG-NI-EDA'),
  ('Niger', 'Gbako', 'NG-NI-GBA'), ('Niger', 'Gurara', 'NG-NI-GUR'), ('Niger', 'Katcha', 'NG-NI-KAT'), ('Niger', 'Kontagora', 'NG-NI-KON'), ('Niger', 'Lapai', 'NG-NI-LAP'),
  ('Niger', 'Lavun', 'NG-NI-LAV'), ('Niger', 'Magama', 'NG-NI-MAG'), ('Niger', 'Mariga', 'NG-NI-MAR'), ('Niger', 'Mashegu', 'NG-NI-MAS'), ('Niger', 'Mokwa', 'NG-NI-MOK'),
  ('Niger', 'Moya', 'NG-NI-MUY'), ('Niger', 'Paikoro', 'NG-NI-PAI'), ('Niger', 'Rafi', 'NG-NI-RAF'), ('Niger', 'Rijau', 'NG-NI-RIJ'), ('Niger', 'Shiroro', 'NG-NI-SHI'),
  ('Niger', 'Suleja', 'NG-NI-SUL'), ('Niger', 'Tafa', 'NG-NI-TAF'), ('Niger', 'Wushishi', 'NG-NI-WUS'), ('Ogun', 'Abeokuta North', 'NG-OG-ANO'), ('Ogun', 'Abeokuta South', 'NG-OG-ASO'),
  ('Ogun', 'Ado-Odo/Ota', 'NG-OG-AOD'), ('Ogun', 'Egbado North', 'NG-OG-ENO'), ('Ogun', 'Egbado South', 'NG-OG-ESO'), ('Ogun', 'Ewekoro', 'NG-OG-EWE'), ('Ogun', 'Ifo', 'NG-OG-IFO'),
  ('Ogun', 'Ijebu East', 'NG-OG-IEA'), ('Ogun', 'Ijebu North', 'NG-OG-INO'), ('Ogun', 'Ijebu North East', 'NG-OG-INE'), ('Ogun', 'Ijebu Ode', 'NG-OG-IOD'), ('Ogun', 'Ikenne', 'NG-OG-IKE'),
  ('Ogun', 'Imeko Afon', 'NG-OG-IAF'), ('Ogun', 'Ipokia', 'NG-OG-IPO'), ('Ogun', 'Obafemi Owode', 'NG-OG-OOW'), ('Ogun', 'Odeda', 'NG-OG-ODE'), ('Ogun', 'Odogbolu', 'NG-OG-ODO'),
  ('Ogun', 'Ogun Waterside', 'NG-OG-OWA'), ('Ogun', 'Remo North', 'NG-OG-RNO'), ('Ogun', 'Shagamu', 'NG-OG-SHA'), ('Ondo', 'Akoko North-East', 'NG-ON-ANE'), ('Ondo', 'Akoko North-West', 'NG-ON-ANW'),
  ('Ondo', 'Akoko South-West', 'NG-ON-ASW'), ('Ondo', 'Akoko South-East', 'NG-ON-ASA'), ('Ondo', 'Akure North', 'NG-ON-ANO'), ('Ondo', 'Akure South', 'NG-ON-ASO'), ('Ondo', 'Ese Odo', 'NG-ON-EOD'),
  ('Ondo', 'Idanre', 'NG-ON-IDA'), ('Ondo', 'Ifedore', 'NG-ON-IFE'), ('Ondo', 'Ilaje', 'NG-ON-ILA'), ('Ondo', 'Ile Oluji/Okeigbo', 'NG-ON-IOO'), ('Ondo', 'Irele', 'NG-ON-IRE'),
  ('Ondo', 'Odigbo', 'NG-ON-ODI'), ('Ondo', 'Okitipupa', 'NG-ON-OKI'), ('Ondo', 'Ondo East', 'NG-ON-OEA'), ('Ondo', 'Ondo West', 'NG-ON-OWE'), ('Ondo', 'Ose', 'NG-ON-OSE'),
  ('Ondo', 'Owo', 'NG-ON-OWO'), ('Osun', 'Atakunmosa East', 'NG-OS-AEA'), ('Osun', 'Atakunmosa West', 'NG-OS-AWE'), ('Osun', 'Aiyedaade', 'NG-OS-AIY'), ('Osun', 'Aiyedire', 'NG-OS-AI1'),
  ('Osun', 'Boluwaduro', 'NG-OS-BOL'), ('Osun', 'Boripe', 'NG-OS-BOR'), ('Osun', 'Ede North', 'NG-OS-ENO'), ('Osun', 'Ede South', 'NG-OS-ESO'), ('Osun', 'Ife Central', 'NG-OS-ICE'),
  ('Osun', 'Ife East', 'NG-OS-IEA'), ('Osun', 'Ife North', 'NG-OS-INO'), ('Osun', 'Ife South', 'NG-OS-ISO'), ('Osun', 'Egbedore', 'NG-OS-EGB'), ('Osun', 'Ejigbo', 'NG-OS-EJI'),
  ('Osun', 'Ifedayo', 'NG-OS-IFE'), ('Osun', 'Ifelodun', 'NG-OS-IF1'), ('Osun', 'Ila', 'NG-OS-ILA'), ('Osun', 'Ilesa East', 'NG-OS-IE1'), ('Osun', 'Ilesa West', 'NG-OS-IWE'),
  ('Osun', 'Irepodun', 'NG-OS-IRE'), ('Osun', 'Irewole', 'NG-OS-IR1'), ('Osun', 'Isokan', 'NG-OS-IS1'), ('Osun', 'Iwo', 'NG-OS-IWO'), ('Osun', 'Obokun', 'NG-OS-OBO'),
  ('Osun', 'Odo Otin', 'NG-OS-OOT'), ('Osun', 'Ola Oluwa', 'NG-OS-OOL'), ('Osun', 'Olorunda', 'NG-OS-OLO'), ('Osun', 'Oriade', 'NG-OS-ORI'), ('Osun', 'Orolu', 'NG-OS-ORO'),
  ('Osun', 'Osogbo', 'NG-OS-OSO'), ('Oyo', 'Afijio', 'NG-OY-AFI'), ('Oyo', 'Akinyele', 'NG-OY-AKI'), ('Oyo', 'Atiba', 'NG-OY-ATI'), ('Oyo', 'Atisbo', 'NG-OY-AT1'),
  ('Oyo', 'Egbeda', 'NG-OY-EGB'), ('Oyo', 'Ibadan North', 'NG-OY-INO'), ('Oyo', 'Ibadan North-East', 'NG-OY-INE'), ('Oyo', 'Ibadan North-West', 'NG-OY-INW'), ('Oyo', 'Ibadan South-East', 'NG-OY-ISE'),
  ('Oyo', 'Ibadan South-West', 'NG-OY-ISW'), ('Oyo', 'Ibarapa Central', 'NG-OY-IC1'), ('Oyo', 'Ibarapa East', 'NG-OY-IEA'), ('Oyo', 'Ibarapa North', 'NG-OY-IN1'), ('Oyo', 'Ido', 'NG-OY-IDO'),
  ('Oyo', 'Irepo', 'NG-OY-IRE'), ('Oyo', 'Iseyin', 'NG-OY-IS1'), ('Oyo', 'Itesiwaju', 'NG-OY-ITE'), ('Oyo', 'Iwajowa', 'NG-OY-IWA'), ('Oyo', 'Kajola', 'NG-OY-KAJ'),
  ('Oyo', 'Lagelu', 'NG-OY-LAG'), ('Oyo', 'Ogbomosho North', 'NG-OY-ONO'), ('Oyo', 'Ogbomosho South', 'NG-OY-OSO'), ('Oyo', 'Ogo Oluwa', 'NG-OY-OGO'), ('Oyo', 'Olorunsogo', 'NG-OY-OLO'),
  ('Oyo', 'Oluyole', 'NG-OY-OLU'), ('Oyo', 'Ona Ara', 'NG-OY-OAR'), ('Oyo', 'Orelope', 'NG-OY-ORE'), ('Oyo', 'Ori Ire', 'NG-OY-ORI'), ('Oyo', 'Oyo', 'NG-OY-OWE'),
  ('Oyo', 'Oyo East', 'NG-OY-OEA'), ('Oyo', 'Saki East', 'NG-OY-SEA'), ('Oyo', 'Saki West', 'NG-OY-SWE'), ('Oyo', 'Surulere', 'NG-OY-SUR'), ('Plateau', 'Bokkos', 'NG-PL-BOK'),
  ('Plateau', 'Barkin Ladi', 'NG-PL-BLA'), ('Plateau', 'Bassa', 'NG-PL-BA1'), ('Plateau', 'Jos East', 'NG-PL-JEA'), ('Plateau', 'Jos North', 'NG-PL-JNO'), ('Plateau', 'Jos South', 'NG-PL-JSO'),
  ('Plateau', 'Kanam', 'NG-PL-KAN'), ('Plateau', 'Kanke', 'NG-PL-KA1'), ('Plateau', 'Langtang South', 'NG-PL-LSO'), ('Plateau', 'Langtang North', 'NG-PL-LNO'), ('Plateau', 'Mangu', 'NG-PL-MAN'),
  ('Plateau', 'Mikang', 'NG-PL-MIK'), ('Plateau', 'Pankshin', 'NG-PL-PAN'), ('Plateau', 'Qua''an Pan', 'NG-PL-QPA'), ('Plateau', 'Riyom', 'NG-PL-RIY'), ('Plateau', 'Shendam', 'NG-PL-SHE'),
  ('Plateau', 'Wase', 'NG-PL-WAS'), ('Rivers', 'Abua/Odual', 'NG-RI-ABU'), ('Rivers', 'Ahoada East', 'NG-RI-AEA'), ('Rivers', 'Ahoada West', 'NG-RI-AWE'), ('Rivers', 'Akuku-Toru', 'NG-RI-ATO'),
  ('Rivers', 'Andoni', 'NG-RI-AND'), ('Rivers', 'Asari-Toru', 'NG-RI-AT1'), ('Rivers', 'Bonny', 'NG-RI-BON'), ('Rivers', 'Degema', 'NG-RI-DEG'), ('Rivers', 'Eleme', 'NG-RI-ELE'),
  ('Rivers', 'Emuoha', 'NG-RI-EMO'), ('Rivers', 'Etche', 'NG-RI-ETC'), ('Rivers', 'Gokana', 'NG-RI-GOK'), ('Rivers', 'Ikwerre', 'NG-RI-IKW'), ('Rivers', 'Khana', 'NG-RI-KHA'),
  ('Rivers', 'Obio/Akpor', 'NG-RI-OBI'), ('Rivers', 'Ogba/Egbema/Ndoni', 'NG-RI-OGB'), ('Rivers', 'Ogu/Bolo', 'NG-RI-OGU'), ('Rivers', 'Okrika', 'NG-RI-OKR'), ('Rivers', 'Omuma', 'NG-RI-OMU'),
  ('Rivers', 'Opobo/Nkoro', 'NG-RI-OPO'), ('Rivers', 'Oyigbo', 'NG-RI-OYI'), ('Rivers', 'Port Harcourt', 'NG-RI-PHA'), ('Rivers', 'Tai', 'NG-RI-TAI'), ('Sokoto', 'Binji', 'NG-SO-BIN'),
  ('Sokoto', 'Bodinga', 'NG-SO-BOD'), ('Sokoto', 'Dange Shuni', 'NG-SO-DSH'), ('Sokoto', 'Gada', 'NG-SO-GAD'), ('Sokoto', 'Goronyo', 'NG-SO-GOR'), ('Sokoto', 'Gudu', 'NG-SO-GUD'),
  ('Sokoto', 'Gwadabawa', 'NG-SO-GAW'), ('Sokoto', 'Illela', 'NG-SO-ILL'), ('Sokoto', 'Isa', 'NG-SO-ISA'), ('Sokoto', 'Kebbe', 'NG-SO-KEB'), ('Sokoto', 'Kware', 'NG-SO-KWA'),
  ('Sokoto', 'Rabah', 'NG-SO-RAB'), ('Sokoto', 'Sabon Birni', 'NG-SO-SBI'), ('Sokoto', 'Shagari', 'NG-SO-SHA'), ('Sokoto', 'Silame', 'NG-SO-SIL'), ('Sokoto', 'Sokoto North', 'NG-SO-SNO'),
  ('Sokoto', 'Sokoto South', 'NG-SO-SSO'), ('Sokoto', 'Tambuwal', 'NG-SO-TAM'), ('Sokoto', 'Tangaza', 'NG-SO-TQN'), ('Sokoto', 'Tureta', 'NG-SO-TUR'), ('Sokoto', 'Wamako', 'NG-SO-WAM'),
  ('Sokoto', 'Wurno', 'NG-SO-WUR'), ('Sokoto', 'Yabo', 'NG-SO-YAB'), ('Taraba', 'Ardo Kola', 'NG-TA-AKO'), ('Taraba', 'Bali', 'NG-TA-BAL'), ('Taraba', 'Donga', 'NG-TA-DON'),
  ('Taraba', 'Gashaka', 'NG-TA-GAS'), ('Taraba', 'Gassol', 'NG-TA-GSS'), ('Taraba', 'Ibi', 'NG-TA-IBI'), ('Taraba', 'Jalingo', 'NG-TA-JAL'), ('Taraba', 'Karim Lamido', 'NG-TA-KLA'),
  ('Taraba', 'Kumi', 'NG-TA-KUR'), ('Taraba', 'Lau', 'NG-TA-LAU'), ('Taraba', 'Sardauna', 'NG-TA-SAR'), ('Taraba', 'Takum', 'NG-TA-TAK'), ('Taraba', 'Ussa', 'NG-TA-USS'),
  ('Taraba', 'Wukari', 'NG-TA-WUK'), ('Taraba', 'Yorro', 'NG-TA-YOR'), ('Taraba', 'Zing', 'NG-TA-ZIN'), ('Yobe', 'Bade', 'NG-YO-BAD'), ('Yobe', 'Bursari', 'NG-YO-BUR'),
  ('Yobe', 'Damaturu', 'NG-YO-DAM'), ('Yobe', 'Fika', 'NG-YO-FIK'), ('Yobe', 'Fune', 'NG-YO-FUN'), ('Yobe', 'Geidam', 'NG-YO-GEI'), ('Yobe', 'Gujba', 'NG-YO-GUJ'),
  ('Yobe', 'Gulani', 'NG-YO-GUL'), ('Yobe', 'Jakusko', 'NG-YO-JAK'), ('Yobe', 'Karasuwa', 'NG-YO-KAR'), ('Yobe', 'Machina', 'NG-YO-MAC'), ('Yobe', 'Nangere', 'NG-YO-NAN'),
  ('Yobe', 'Nguru', 'NG-YO-NGU'), ('Yobe', 'Potiskum', 'NG-YO-POT'), ('Yobe', 'Tarmuwa', 'NG-YO-TAR'), ('Yobe', 'Yunusari', 'NG-YO-YUN'), ('Yobe', 'Yusufari', 'NG-YO-YUS'),
  ('Zamfara', 'Anka', 'NG-ZA-ANK'), ('Zamfara', 'Bakura', 'NG-ZA-BAK'), ('Zamfara', 'Birnin Magaji/Kiyaw', 'NG-ZA-BMA'), ('Zamfara', 'Bukkuyum', 'NG-ZA-BUK'), ('Zamfara', 'Bungudu', 'NG-ZA-BUN'),
  ('Zamfara', 'Gummi', 'NG-ZA-GUM'), ('Zamfara', 'Gusau', 'NG-ZA-GUS'), ('Zamfara', 'Kaura Namoda', 'NG-ZA-KNA'), ('Zamfara', 'Maradun', 'NG-ZA-MAR'), ('Zamfara', 'Maru', 'NG-ZA-MA1'),
  ('Zamfara', 'Shinkafi', 'NG-ZA-SHI'), ('Zamfara', 'Talata Mafara', 'NG-ZA-TMA'), ('Zamfara', 'Chafe', 'NG-ZA-TSA'), ('Zamfara', 'Zurmi', 'NG-ZA-ZUR')
) v(state, lga, code)
where l.state = v.state and l.lga = v.lga and l.nrs_code is distinct from v.code;
do $$
declare n int;
begin
  select count(*) into n from public.ng_lgas where nrs_code is null;
  if n > 0 then raise exception 'ng_lgas: % local government areas have no NRS code.', n; end if;
end $$;
create unique index if not exists ng_lgas_nrs_code on public.ng_lgas(nrs_code);

-- The NRS codes of a place named as Counta keeps it: {state: 'NG-LA', lga: 'NG-LA-IKE'}, the LGA null when it is not
-- known. Null when the state is not a Nigerian state.
create or replace function private.nrs_place(p_state text, p_lga text) returns jsonb
language sql stable set search_path = public, private as $$
  select case when s.state is null then null else jsonb_build_object(
    'state', (select left(min(l.nrs_code), 5) from public.ng_lgas l where l.state = s.state),
    'lga', (select l.nrs_code from public.ng_lgas l where l.state = s.state and l.lga = private.ng_lga(s.state, p_lga))) end
  from (select private.ng_state(p_state) state) s
$$;

-- ---------------------------------------------------------------------------
-- 2. Addresses and government buyers
-- ---------------------------------------------------------------------------
alter table public.locations add column if not exists city text;
alter table public.locations add column if not exists postcode text;
alter table public.customers add column if not exists postcode text;

-- A Nigerian postcode is 6 digits (spaces taken out). A customer abroad may have any postcode up to 12 characters.
create or replace function private.on_postcode_saved() returns trigger
language plpgsql set search_path = public, private as $$
declare v_ng boolean;
begin
  new.postcode := nullif(regexp_replace(btrim(coalesce(new.postcode, '')), '\s+', ' ', 'g'), '');
  if tg_table_name = 'locations' then
    new.city := nullif(left(btrim(coalesce(new.city, '')), 80), '');
    v_ng := true;
  else
    v_ng := coalesce(upper(new.country), 'NG') = 'NG';
  end if;
  if new.postcode is not null then
    if v_ng then
      new.postcode := replace(new.postcode, ' ', '');
      if new.postcode !~ '^[0-9]{6}$' then raise exception 'A Nigerian postcode has 6 digits.'; end if;
    elsif length(new.postcode) > 12 then
      raise exception 'That postcode is too long.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists locations_postcode on public.locations;
create trigger locations_postcode before insert or update of city, postcode on public.locations for each row execute function private.on_postcode_saved();
drop trigger if exists customers_postcode on public.customers;
create trigger customers_postcode before insert or update of postcode, country on public.customers for each row execute function private.on_postcode_saved();

alter table public.customers drop constraint if exists customers_kind_check;
alter table public.customers add constraint customers_kind_check check (kind in ('individual', 'business', 'government'));

-- Customers: as before, with the postcode, and government bodies as a kind of customer.
create or replace function public.save_customer(p_org uuid, p_customer jsonb) returns uuid
language plpgsql security definer set search_path = public, private as $$
declare m public.members; c public.customers; v_country text; v_id uuid; v_agent boolean := (p_customer->>'wvat_agent')::boolean;
begin
  m := private.require(p_org, 'record_sales');
  if nullif(p_customer->>'kind', '') is not null and p_customer->>'kind' not in ('individual', 'business', 'government') then
    raise exception 'Choose whether the customer is a person, a business or a government body.';
  end if;
  if nullif(p_customer->>'id', '') is not null then
    select * into c from customers where id = (p_customer->>'id')::uuid and org_id = p_org;
  end if;
  if p_customer ? 'tin' then
    v_country := coalesce(upper(nullif(trim(p_customer->>'country'), '')), c.country, 'NG');
    p_customer := p_customer || jsonb_build_object('tin', case when v_country = 'NG' then private.tax_id_input(p_customer->>'tin', c.tin, 'The customer''s Tax ID')
      else nullif(left(trim(p_customer->>'tin'), 40), '') end);
  end if;
  if v_agent is not null and v_agent is distinct from coalesce(c.wvat_agent, false)
     and not (private.perm_of(m, 'approve_adjustments') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only a manager, an accountant or the owner marks a customer as a withholding VAT agent.';
  end if;
  v_id := private.upsert_customer(p_org, p_customer, m);
  if v_agent is not null then update customers set wvat_agent = v_agent where id = v_id; end if;
  if p_customer ? 'lga' then update customers set lga = nullif(trim(p_customer->>'lga'), '') where id = v_id; end if;
  if p_customer ? 'postcode' then update customers set postcode = nullif(trim(p_customer->>'postcode'), '') where id = v_id; end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Each business's NRS settings
-- ---------------------------------------------------------------------------
-- The key, secret and crypto_keys.txt are Cloud KMS ciphertext (nrs-credentials, an HSM key), bound to the business and
-- the field, so a value copied to another business or field does not decrypt. keys_version goes up whenever something the
-- NRS test depends on changes; a test counts only for the version it ran on.
create table if not exists public.einvoice_settings (
  org_id uuid primary key references public.orgs(id) on delete cascade,
  enabled boolean not null default false,
  enabled_at timestamptz,
  platform_keys boolean not null default false,
  platform_keys_note text,
  business_id text check (business_id is null or business_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  service_id text check (service_id is null or service_id ~ '^[A-Z0-9]{8}$'),
  api_key_ct text check (api_key_ct is null or length(api_key_ct) <= 8192),
  api_key_hint text check (api_key_hint is null or length(api_key_hint) <= 40),
  api_secret_ct text check (api_secret_ct is null or length(api_secret_ct) <= 8192),
  api_secret_hint text check (api_secret_hint is null or length(api_secret_hint) <= 40),
  crypto_ct text check (crypto_ct is null or length(crypto_ct) <= 16384),
  crypto_hint text check (crypto_hint is null or length(crypto_hint) <= 40),
  keys_version int not null default 1,
  service_code text check (service_code is null or service_code ~ '^[0-9]{4}$'),
  service_basis jsonb,
  service_checked_at timestamptz,
  checked_at timestamptz,
  check_ok boolean,
  check_note text,
  check_by uuid references auth.users(id) on delete set null,
  check_version int,
  check_tried_at timestamptz,
  check_tried_version int,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
create index if not exists einvoice_settings_check_by on public.einvoice_settings(check_by);
create index if not exists einvoice_settings_updated_by on public.einvoice_settings(updated_by);
alter table public.einvoice_settings enable row level security;
revoke all on public.einvoice_settings from anon, authenticated;

-- Who sees the e-invoicing settings: whoever changes settings, keeps the books or files tax. Changing them takes
-- manage_settings.
create or replace function private.einvoice_viewer(p_org uuid) returns public.members
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members;
begin
  m := private.require(p_org, null);
  if not (private.perm_of(m, 'manage_settings') or private.perm_of(m, 'keep_books') or private.perm_of(m, 'file_tax')) then
    raise exception 'Your role does not see the e-invoicing settings.' using errcode = '42501';
  end if;
  return m;
end $$;

-- Whether a code is on one of NRS's lists. Before the list has been copied from NRS at all, any well-formed code passes.
create or replace function private.nrs_code_ok(p_list text, p_code text) returns boolean
language sql stable set search_path = public, private as $$
  select exists (select 1 from public.nrs_codes where list = p_list and code = p_code)
      or not exists (select 1 from public.nrs_codes where list = p_list)
$$;

-- NRS's words for a code.
create or replace function private.nrs_label(p_list text, p_code text) returns text
language sql stable set search_path = public, private as $$
  select label from public.nrs_codes where list = p_list and code = p_code
$$;

-- An HS code as NRS lists it (1902.30), from what was typed: 190230, 1902 30, 1902.30.00.
create or replace function private.hs_code(p text) returns text
language sql immutable as $$
  select case when d ~ '^[0-9]{6}' then substr(d, 1, 4) || '.' || substr(d, 5, 2) end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') d) x
$$;

-- ---------------------------------------------------------------------------
-- 4. HS codes on items
-- ---------------------------------------------------------------------------
-- hs_basis: {source: 'gemini'|'manual', code, reason, confidence, model, at, by, ai (Gemini's answer a person replaced)}
alter table public.items add column if not exists hs_code text;
alter table public.items add column if not exists hs_basis jsonb;
alter table public.items add column if not exists hs_checked_at timestamptz;
alter table public.items add column if not exists hs_review boolean not null default false;
alter table public.items drop constraint if exists items_hs_code_check;
alter table public.items add constraint items_hs_code_check check (hs_code is null or hs_code ~ '^[0-9]{4}\.[0-9]{2}$');
create index if not exists items_hs_unchecked on public.items(org_id, created_at) where hs_checked_at is null and not archived;

-- NRS's HS codes or service codes, by the start of the code or by words in its description.
create or replace function public.nrs_code_search(p_list text, p_q text, p_limit int default 20) returns jsonb
language plpgsql stable set search_path = public, private as $$
declare v_q text := btrim(coalesce(p_q, '')); v_digits text := regexp_replace(coalesce(p_q, ''), '[^0-9]', '', 'g');
  v_words text[]; v_limit int := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_list not in ('hs-codes', 'services-codes') then raise exception 'Search HS codes or service codes.'; end if;
  if v_q = '' then return '[]'::jsonb; end if;
  if v_q ~ '^[0-9 .]+$' then
    return (select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'label', x.label) order by x.code), '[]'::jsonb)
      from (select code, label from nrs_codes where list = p_list and replace(code, '.', '') like v_digits || '%' order by code limit v_limit) x);
  end if;
  select array_agg(w) into v_words from regexp_split_to_table(lower(v_q), '[^a-z0-9]+') w where length(w) >= 2;
  if v_words is null then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'label', x.label) order by x.rk, length(x.label), x.code), '[]'::jsonb)
    from (select c.code, c.label, case when lower(c.label) like v_words[1] || '%' then 0 else 1 end rk from nrs_codes c
          where c.list = p_list and (select bool_and(lower(coalesce(c.label, '')) like '%' || w || '%') from unnest(v_words) w)
          order by rk, length(c.label), c.code limit v_limit) x);
end $$;

-- A person sets or confirms an item's HS code. Gemini leaves it alone after that.
create or replace function public.set_item_hs_code(p_item uuid, p_code text, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare it public.items; m public.members; v_code text := private.hs_code(p_code);
begin
  select * into it from items where id = p_item for update;
  if not found then raise exception 'Item not found.'; end if;
  m := private.require(it.org_id, null);
  if not (private.perm_of(m, 'edit_prices') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only someone who edits prices or keeps the books sets HS codes.' using errcode = '42501';
  end if;
  if v_code is null then raise exception 'An HS code has 6 digits, like 1902.30.'; end if;
  if not private.nrs_code_ok('hs-codes', v_code) then raise exception '% is not on NRS''s list of HS codes.', v_code; end if;
  update items set hs_code = v_code, hs_review = false, hs_checked_at = now(),
    hs_basis = jsonb_build_object('source', 'manual', 'code', v_code, 'reason', nullif(left(btrim(coalesce(p_reason, '')), 400), ''), 'by', m.display_name, 'at', now(),
      'ai', case when coalesce(it.hs_basis->>'source', '') = 'manual' then it.hs_basis->'ai' else it.hs_basis end)
  where id = it.id;
  return jsonb_build_object('id', it.id, 'hs_code', v_code, 'label', private.nrs_label('hs-codes', v_code));
end $$;

-- Ask Gemini to choose again (after a person is unsure, or to undo their choice).
create or replace function public.recheck_item_hs_code(p_item uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare it public.items; m public.members;
begin
  select * into it from items where id = p_item;
  if not found then raise exception 'Item not found.'; end if;
  m := private.require(it.org_id, null);
  if not (private.perm_of(m, 'edit_prices') or private.perm_of(m, 'keep_books')) then
    raise exception 'Only someone who edits prices or keeps the books sets HS codes.' using errcode = '42501';
  end if;
  update items set hs_checked_at = null, hs_review = false,
    hs_basis = case when hs_basis->>'source' = 'manual' then hs_basis->'ai' else hs_basis end
  where id = it.id;
  if exists (select 1 from einvoice_settings where org_id = it.org_id) then
    perform private.call_function('ai', jsonb_build_object('action', 'nrs_codes_pending'));
  end if;
end $$;

-- A renamed or redescribed item is coded again unless a person chose its code.
create or replace function private.on_item_renamed_hs() returns trigger
language plpgsql set search_path = public, private as $$
begin
  if (new.name is distinct from old.name or new.category is distinct from old.category or new.description is distinct from old.description)
     and coalesce(new.hs_basis->>'source', '') <> 'manual' then
    new.hs_checked_at := null;
  end if;
  return new;
end $$;
drop trigger if exists items_hs_recheck on public.items;
create trigger items_hs_recheck before update of name, category, description on public.items for each row execute function private.on_item_renamed_hs();

-- Items waiting for Gemini, in businesses that have started on e-invoicing: newest first.
create or replace function public.svc_items_for_hs(p_limit int default 100) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'org_id', i.org_id, 'name', i.name, 'category', i.category, 'brand', i.brand,
      'description', left(i.description, 300), 'item_type', i.item_type, 'unit', i.selling_unit, 'current', i.hs_code, 'industry', o.industry)), '[]'::jsonb)
  from (select i.* from items i join einvoice_settings s on s.org_id = i.org_id
        where i.hs_checked_at is null and not i.archived and coalesce(i.hs_basis->>'source', '') <> 'manual'
        order by i.created_at desc limit least(greatest(coalesce(p_limit, 100), 1), 200)) i
  join orgs o on o.id = i.org_id
$$;

-- Codes on one of NRS's lists that start with p_prefix (an HS heading such as 1902, or a chapter such as 19).
create or replace function public.svc_nrs_codes_under(p_list text, p_prefix text, p_limit int default 120) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'label', x.label) order by x.code), '[]'::jsonb)
  from (select code, label from nrs_codes
        where list = p_list and coalesce(p_prefix, '') ~ '^[0-9]{2,6}$' and replace(code, '.', '') like p_prefix || '%'
        order by code limit least(greatest(coalesce(p_limit, 120), 1), 300)) x
$$;

-- Gemini's answer for an item. p: {code, confidence, reason, model, tried}. A code not on NRS's list is no answer. Below
-- the business's confidence threshold (at least 80%) the code is used and marked to confirm.
create or replace function public.svc_set_item_hs(p_item uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare it public.items; v_code text := private.hs_code(p->>'code'); v_conf numeric := least(greatest(coalesce(private.num(p->>'confidence'), 0), 0), 1);
  v_threshold numeric;
begin
  select * into it from items where id = p_item for update;
  if not found then return jsonb_build_object('ok', false); end if;
  if coalesce(it.hs_basis->>'source', '') = 'manual' then
    update items set hs_checked_at = now() where id = it.id;
    return jsonb_build_object('ok', true, 'kept', 'manual');
  end if;
  if v_code is not null and not exists (select 1 from nrs_codes where list = 'hs-codes' and code = v_code)
     and exists (select 1 from nrs_codes where list = 'hs-codes') then
    v_code := null;
  end if;
  if v_code is null then
    update items set hs_checked_at = now(), hs_review = true,
      hs_basis = jsonb_build_object('source', 'gemini', 'code', null, 'reason', left(coalesce(nullif(p->>'reason', ''), 'Gemini could not find the HS code.'), 400),
        'model', p->>'model', 'at', now(), 'tried', p->'tried')
    where id = it.id;
    return jsonb_build_object('ok', false, 'reason', 'no_code');
  end if;
  select greatest(coalesce(auto_post_threshold, 0.8), 0.8) into v_threshold from orgs where id = it.org_id;
  update items set hs_code = v_code, hs_checked_at = now(), hs_review = v_conf < v_threshold,
    hs_basis = jsonb_build_object('source', 'gemini', 'code', v_code, 'reason', left(p->>'reason', 400), 'confidence', v_conf, 'model', p->>'model', 'at', now())
  where id = it.id;
  return jsonb_build_object('ok', true, 'code', v_code, 'review', v_conf < v_threshold);
end $$;

-- ---------------------------------------------------------------------------
-- 5. The business's service code
-- ---------------------------------------------------------------------------
-- Businesses waiting for Gemini to choose their service code, with what they do and some of what they sell.
create or replace function public.svc_orgs_for_service_code(p_limit int default 10) returns jsonb
language sql stable security definer set search_path = public, private as $$
  select coalesce(jsonb_agg(jsonb_build_object('org_id', o.id, 'name', o.name, 'industry', o.industry, 'offering', o.offering,
      'principal_activity', o.principal_activity,
      'items', (select coalesce(jsonb_agg(x.name), '[]'::jsonb) from (select name from items where org_id = o.id and not archived order by created_at desc limit 12) x),
      'services', (select coalesce(jsonb_agg(x.description), '[]'::jsonb) from (select distinct left(sl.description, 120) description from sale_lines sl
                    where sl.org_id = o.id and sl.kind = 'service' and sl.description is not null limit 12) x))), '[]'::jsonb)
  from (select s.org_id from einvoice_settings s
        where s.service_checked_at is null and coalesce(s.service_basis->>'source', '') <> 'manual'
        order by s.created_at limit least(greatest(coalesce(p_limit, 10), 1), 50)) s
  join orgs o on o.id = s.org_id
$$;

-- Gemini's answer for a business. p: {code, confidence, reason, model}.
create or replace function public.svc_set_service_code(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.einvoice_settings; v_code text := nullif(regexp_replace(coalesce(p->>'code', ''), '[^0-9]', '', 'g'), '');
  v_conf numeric := least(greatest(coalesce(private.num(p->>'confidence'), 0), 0), 1);
begin
  select * into s from einvoice_settings where org_id = p_org for update;
  if not found then return jsonb_build_object('ok', false); end if;
  if coalesce(s.service_basis->>'source', '') = 'manual' then
    update einvoice_settings set service_checked_at = now() where org_id = p_org;
    return jsonb_build_object('ok', true, 'kept', 'manual');
  end if;
  if v_code is not null and (v_code !~ '^[0-9]{4}$' or not private.nrs_code_ok('services-codes', v_code)) then v_code := null; end if;
  update einvoice_settings set service_checked_at = now(),
    service_code = coalesce(v_code, service_code),
    service_basis = jsonb_build_object('source', 'gemini', 'code', v_code, 'reason', left(coalesce(nullif(p->>'reason', ''), case when v_code is null then 'Gemini could not choose a service code.' end), 400),
      'confidence', v_conf, 'model', p->>'model', 'at', now())
  where org_id = p_org;
  return jsonb_build_object('ok', v_code is not null, 'code', v_code);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Readiness
-- ---------------------------------------------------------------------------
-- A list in words: "city", "city and LGA", "city, state and LGA".
create or replace function private.words_and(p text[]) returns text
language sql immutable as $$
  select case when coalesce(cardinality(p), 0) = 0 then '' when cardinality(p) = 1 then p[1]
    else array_to_string(p[1:cardinality(p) - 1], ', ') || ' and ' || p[cardinality(p)] end
$$;

-- What NRS needs from the business before its first e-invoice, in order. Each: {id, ok, blocking, title, detail, link}.
-- The ones marked blocking must all be ok before e-invoicing can be switched on.
create or replace function private.einvoice_readiness(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare o public.orgs; s public.einvoice_settings; b public.locations; v jsonb := '[]'::jsonb; v_missing text[];
  n_items int; n_coded int; n_wait int; n_review int; n_cust int; v_tin text;
begin
  select * into o from orgs where id = p_org;
  select * into s from einvoice_settings where org_id = p_org;
  select * into b from locations where org_id = p_org order by is_main desc, created_at limit 1;

  -- The business's Tax ID.
  v_tin := regexp_replace(coalesce(o.tin, ''), '[^0-9]', '', 'g');
  v := v || jsonb_build_object('id', 'tin', 'blocking', true, 'ok', v_tin <> '', 'title', 'The business''s Tax ID', 'link', '/settings#books',
    'detail', case when v_tin = '' then 'Add the business''s Tax ID in Settings, under Books and tax.'
      when o.tin_status in ('verified', 'confirmed') then 'Tax ID ending ' || right(v_tin, 4) || ', checked with NRS.'
      else 'Tax ID ending ' || right(v_tin, 4) || '. It has not been checked with NRS yet.' end);

  -- Email and phone: NRS puts both on the supplier's side of each invoice.
  v_missing := array_remove(array[case when nullif(btrim(coalesce(o.email, '')), '') is null then 'email' end,
    case when nullif(btrim(coalesce(o.phone, '')), '') is null then 'phone number' end], null);
  v := v || jsonb_build_object('id', 'contact', 'blocking', true, 'ok', cardinality(v_missing) = 0, 'title', 'Email and phone', 'link', '/settings#business',
    'detail', case when cardinality(v_missing) = 0 then o.email || ' and ' || o.phone || '.' else 'Add the business''s ' || private.words_and(v_missing) || ' in Settings.' end);

  -- The address on the invoice: the main branch's street, city, state and LGA. A postcode is asked for, not required.
  v_missing := array_remove(array[case when nullif(btrim(coalesce(b.address, '')), '') is null then 'street address' end,
    case when b.city is null then 'city' end, case when b.state is null then 'state' end, case when b.lga is null then 'LGA' end], null);
  v := v || jsonb_build_object('id', 'address', 'blocking', true, 'ok', b.id is not null and cardinality(v_missing) = 0, 'title', 'The business address', 'link', '/inventory/locations',
    'detail', case when b.id is null then 'Add the main branch under Locations.'
      when cardinality(v_missing) = 0 then b.address || ', ' || b.city || ', ' || b.lga || ', ' || b.state || coalesce(' ' || b.postcode, '') || '.'
        || case when b.postcode is null then ' Add the postcode if you know it.' else '' end
      else 'Add the ' || private.words_and(v_missing) || ' of ' || b.name || ' under Locations.' end);

  -- The keys.
  v_missing := array_remove(array[case when s.business_id is null then 'Business ID' end, case when s.service_id is null then 'Service ID' end,
    case when s.api_key_ct is null then 'API key' end, case when s.api_secret_ct is null then 'API secret' end,
    case when s.crypto_ct is null then 'crypto_keys.txt' end], null);
  v := v || jsonb_build_object('id', 'keys', 'blocking', true, 'ok', coalesce(s.platform_keys, false) or (s.org_id is not null and cardinality(v_missing) = 0),
    'title', 'Your NRS keys', 'link', '/settings#einvoicing',
    'detail', case when s.platform_keys then 'Running on TaxStreem''s keys while NRS is in test mode. Add your own before you go live.'
      when s.org_id is null or cardinality(v_missing) = 5 then 'Add the Business ID, Service ID, API key, API secret and crypto_keys.txt from your NRS dashboard.'
      when cardinality(v_missing) = 0 then 'All five are saved.'
      else 'Add the ' || private.words_and(v_missing) || '.' end);

  -- NRS has accepted them.
  v := v || jsonb_build_object('id', 'check', 'blocking', true, 'ok', coalesce(s.check_ok, false) and s.check_version = s.keys_version,
    'title', 'NRS accepts the keys', 'link', '/settings#einvoicing',
    'detail', case when s.checked_at is null or s.check_version is distinct from s.keys_version then 'Test the keys with NRS.'
      else coalesce(s.check_note, case when s.check_ok then 'NRS accepted them.' else 'NRS did not accept them.' end) end);

  -- The service code. Required when the business sells services; goods sellers use it for delivery and other service lines.
  v := v || jsonb_build_object('id', 'service', 'blocking', coalesce(o.offering, 'goods') in ('services', 'both'), 'ok', s.service_code is not null,
    'title', 'Service code', 'link', '/settings#einvoicing',
    'detail', case when s.service_code is not null then s.service_code || ' ' || coalesce(private.nrs_label('services-codes', s.service_code), '') || '.'
      when s.org_id is not null and s.service_checked_at is null then 'Gemini is choosing it.'
      else 'Choose the code for the services you sell.' end);

  -- HS codes on items: Gemini chooses them; an invoice line waits for its item's code.
  select count(*), count(*) filter (where hs_code is not null), count(*) filter (where hs_checked_at is null and coalesce(hs_basis->>'source', '') <> 'manual'),
         count(*) filter (where hs_review)
    into n_items, n_coded, n_wait, n_review
  from items where org_id = p_org and not archived;
  v := v || jsonb_build_object('id', 'items', 'blocking', false, 'ok', n_coded = n_items and n_review = 0, 'title', 'HS codes on items', 'link', '/inventory/items',
    'counts', jsonb_build_object('items', n_items, 'coded', n_coded, 'waiting', n_wait, 'review', n_review),
    'detail', case when n_items = 0 then 'No items yet.'
      else n_coded || ' of ' || n_items || case when n_items = 1 then ' item has' else ' items have' end || ' an HS code.'
        || case when n_wait > 0 and s.org_id is not null then ' Gemini is choosing ' || n_wait || ' more.' else '' end
        || case when n_review > 0 then ' ' || n_review || ' to confirm.' else '' end end);

  -- Business and government customers need a Tax ID on their invoices.
  select count(*) into n_cust from customers where org_id = p_org and not archived and kind in ('business', 'government')
    and coalesce(upper(country), 'NG') = 'NG' and nullif(btrim(coalesce(tin, '')), '') is null;
  v := v || jsonb_build_object('id', 'customers', 'blocking', false, 'ok', n_cust = 0, 'title', 'Tax IDs of business customers', 'link', '/sell/customers',
    'detail', case when n_cust = 0 then 'Every business and government customer has a Tax ID.'
      else n_cust || case when n_cust = 1 then ' business or government customer has' else ' business or government customers have' end
        || ' no Tax ID. Invoices to them wait until one is added.' end);
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 7. The settings in the app
-- ---------------------------------------------------------------------------
create or replace function public.einvoice_settings_get(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare m public.members; s public.einvoice_settings; v_ready jsonb;
begin
  m := private.einvoice_viewer(p_org);
  select * into s from einvoice_settings where org_id = p_org;
  v_ready := private.einvoice_readiness(p_org);
  return jsonb_build_object(
    'started', s.org_id is not null,
    'enabled', coalesce(s.enabled, false), 'enabled_at', s.enabled_at,
    'platform_keys', coalesce(s.platform_keys, false),
    'business_id', s.business_id, 'service_id', s.service_id,
    'keys', jsonb_build_object('api_key', s.api_key_hint, 'api_secret', s.api_secret_hint, 'crypto_keys', s.crypto_hint),
    'service', case when s.service_code is null then null else jsonb_build_object('code', s.service_code, 'label', private.nrs_label('services-codes', s.service_code),
      'source', s.service_basis->>'source', 'reason', s.service_basis->>'reason', 'confidence', s.service_basis->'confidence') end,
    'service_waiting', s.org_id is not null and s.service_checked_at is null,
    'check', case when s.checked_at is null then null else jsonb_build_object('at', s.checked_at, 'ok', s.check_ok, 'note', s.check_note,
      'current', s.check_version = s.keys_version) end,
    'readiness', v_ready,
    'ready', not exists (select 1 from jsonb_array_elements(v_ready) r where (r->>'blocking')::boolean and not (r->>'ok')::boolean),
    'can', jsonb_build_object('edit', private.perm_of(m, 'manage_settings')));
end $$;

-- p: {business_id, service_id, service_code, enabled}, any of them. The first call starts e-invoicing for the business
-- (Gemini then chooses its HS codes and service code). A changed Business ID or Service ID needs a new NRS test, so
-- e-invoicing goes off until it passes and is switched on again. An empty service_code hands the choice back to Gemini.
create or replace function public.einvoice_settings_set(p_org uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare m public.members; s public.einvoice_settings; v_new uuid; v_biz text; v_svc text; v_code text; v_changed boolean := false;
  v_kick boolean := false; r jsonb;
begin
  m := private.require(p_org, 'manage_settings');
  p := coalesce(p, '{}'::jsonb);
  insert into einvoice_settings (org_id, updated_by) values (p_org, auth.uid()) on conflict (org_id) do nothing returning org_id into v_new;
  v_kick := v_new is not null;
  select * into s from einvoice_settings where org_id = p_org for update;
  if p ? 'business_id' then
    v_biz := lower(nullif(btrim(coalesce(p->>'business_id', '')), ''));
    if v_biz is not null and v_biz !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'The Business ID is the long code on your NRS dashboard, in five groups like 6dc03c76-1d83-4a39-a4de-51bd70547aef.';
    end if;
    if v_biz is distinct from s.business_id then update einvoice_settings set business_id = v_biz where org_id = p_org; v_changed := true; end if;
  end if;
  if p ? 'service_id' then
    v_svc := nullif(upper(regexp_replace(coalesce(p->>'service_id', ''), '\s', '', 'g')), '');
    if v_svc is not null and v_svc !~ '^[A-Z0-9]{8}$' then raise exception 'The Service ID is 8 letters and numbers, like 94ND90NR.'; end if;
    if v_svc is distinct from s.service_id then update einvoice_settings set service_id = v_svc where org_id = p_org; v_changed := true; end if;
  end if;
  if v_changed and not s.platform_keys then
    update einvoice_settings set keys_version = keys_version + 1, enabled = false where org_id = p_org;
  end if;
  if p ? 'service_code' then
    v_code := nullif(regexp_replace(coalesce(p->>'service_code', ''), '[^0-9]', '', 'g'), '');
    if v_code is null then
      update einvoice_settings set service_code = null, service_basis = null, service_checked_at = null where org_id = p_org;
      v_kick := true;
    else
      if v_code !~ '^[0-9]{4}$' or not private.nrs_code_ok('services-codes', v_code) then
        raise exception '% is not on NRS''s list of service codes.', coalesce(nullif(btrim(p->>'service_code'), ''), v_code);
      end if;
      update einvoice_settings set service_code = v_code, service_checked_at = now(),
        service_basis = jsonb_build_object('source', 'manual', 'code', v_code, 'by', m.display_name, 'at', now(),
          'ai', case when coalesce(s.service_basis->>'source', '') = 'manual' then s.service_basis->'ai' else s.service_basis end)
      where org_id = p_org;
    end if;
  end if;
  if p ? 'enabled' then
    if coalesce((p->>'enabled')::boolean, false) then
      select x into r from jsonb_array_elements(private.einvoice_readiness(p_org)) x where (x->>'blocking')::boolean and not (x->>'ok')::boolean limit 1;
      if r is not null then raise exception 'Not ready yet. %', r->>'detail'; end if;
      update einvoice_settings set enabled = true, enabled_at = now() where org_id = p_org;
    else
      update einvoice_settings set enabled = false where org_id = p_org;
    end if;
  end if;
  update einvoice_settings set updated_at = now(), updated_by = auth.uid() where org_id = p_org;
  if v_kick then perform private.call_function('ai', jsonb_build_object('action', 'nrs_codes_pending')); end if;
  return public.einvoice_settings_get(p_org);
end $$;

-- The einvoice function saves the key, secret and crypto_keys.txt, already wrapped by Cloud KMS. p: {api_key: {ct, hint}
-- or null, api_secret: ..., crypto_keys: ...}; a key left out stays as it is, null removes it. New keys need a new test,
-- so e-invoicing goes off until it passes (unless the business runs on TaxStreem's keys, which these do not change).
create or replace function public.svc_einvoice_keys_save(p_org uuid, p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.einvoice_settings; k text; v_ct text; v_hint text; v_changed boolean := false;
begin
  insert into einvoice_settings (org_id, updated_by) values (p_org, p_user) on conflict (org_id) do nothing;
  select * into s from einvoice_settings where org_id = p_org for update;
  foreach k in array array['api_key', 'api_secret', 'crypto_keys'] loop
    if not (p ? k) then continue; end if;
    v_ct := nullif(p->k->>'ct', ''); v_hint := nullif(left(coalesce(p->k->>'hint', ''), 40), '');
    if v_ct is not null and v_ct !~ '^[A-Za-z0-9+/=]+$' then raise exception 'The % is not Cloud KMS ciphertext.', k; end if;
    if k = 'api_key' then update einvoice_settings set api_key_ct = v_ct, api_key_hint = case when v_ct is null then null else v_hint end where org_id = p_org;
    elsif k = 'api_secret' then update einvoice_settings set api_secret_ct = v_ct, api_secret_hint = case when v_ct is null then null else v_hint end where org_id = p_org;
    else update einvoice_settings set crypto_ct = v_ct, crypto_hint = case when v_ct is null then null else v_hint end where org_id = p_org;
    end if;
    v_changed := true;
  end loop;
  if v_changed and not s.platform_keys then
    update einvoice_settings set keys_version = keys_version + 1, enabled = false where org_id = p_org;
  end if;
  update einvoice_settings set updated_at = now(), updated_by = p_user where org_id = p_org;
  select * into s from einvoice_settings where org_id = p_org;
  return jsonb_build_object('ok', true, 'version', s.keys_version, 'platform_keys', s.platform_keys,
    'keys', jsonb_build_object('api_key', s.api_key_hint, 'api_secret', s.api_secret_hint, 'crypto_keys', s.crypto_hint));
end $$;

-- A business's NRS test starting: what it runs on, and the version of the keys it checks. The same keys are tested once
-- every 15 seconds at most; new keys straight away.
create or replace function public.svc_einvoice_check_begin(p_org uuid) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare s public.einvoice_settings;
begin
  select * into s from einvoice_settings where org_id = p_org for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_started'); end if;
  if s.check_tried_at > now() - interval '15 seconds' and s.check_tried_version = s.keys_version then
    return jsonb_build_object('ok', false, 'reason', 'too_soon');
  end if;
  update einvoice_settings set check_tried_at = now(), check_tried_version = s.keys_version where org_id = p_org;
  return jsonb_build_object('ok', true, 'platform_keys', s.platform_keys, 'business_id', s.business_id, 'service_id', s.service_id,
    'api_key_ct', s.api_key_ct, 'api_secret_ct', s.api_secret_ct, 'crypto_ct', s.crypto_ct, 'version', s.keys_version);
end $$;

-- What the test found. It counts only if the keys have not changed while it ran.
create or replace function public.svc_einvoice_check_done(p_org uuid, p_version int, p_user uuid, p_ok boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public, private as $$
begin
  update einvoice_settings set checked_at = now(), check_ok = coalesce(p_ok, false), check_note = left(coalesce(p_note, ''), 1000),
    check_by = p_user, check_version = p_version
  where org_id = p_org and keys_version = p_version;
  return jsonb_build_object('saved', found);
end $$;

-- ---------------------------------------------------------------------------
-- 8. The IRN
-- ---------------------------------------------------------------------------
-- The invoice number with anything but letters and digits taken out, the business's Service ID and the issue date:
-- INV0001-94ND90NR-20261110. Null when any part is missing.
create or replace function private.nrs_irn(p_number text, p_service_id text, p_day date) returns text
language sql immutable as $$
  select case when x.n = '' or coalesce(p_service_id, '') !~ '^[A-Z0-9]{8}$' or p_day is null then null
    else x.n || '-' || p_service_id || '-' || to_char(p_day, 'YYYYMMDD') end
  from (select regexp_replace(coalesce(p_number, ''), '[^A-Za-z0-9]', '', 'g') n) x
$$;

-- ---------------------------------------------------------------------------
-- 9. Gemini's codes, every five minutes
-- ---------------------------------------------------------------------------
create or replace function private.einvoice_tick() returns void
language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from items i join einvoice_settings s on s.org_id = i.org_id
             where i.hs_checked_at is null and not i.archived and coalesce(i.hs_basis->>'source', '') <> 'manual')
     or exists (select 1 from einvoice_settings where service_checked_at is null and coalesce(service_basis->>'source', '') <> 'manual') then
    perform private.call_function('ai', jsonb_build_object('action', 'nrs_codes_pending'));
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'counta-einvoice';
    perform cron.schedule('counta-einvoice', '*/5 * * * *', 'select private.einvoice_tick()');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 10. TaxStreem's admins
-- ---------------------------------------------------------------------------
-- A business's e-invoicing as the admin portal shows it. Which keys are saved, never what they are.
create or replace function public.admin_einvoice_business(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
declare s public.einvoice_settings; v_ready jsonb;
begin
  perform private.require_staff();
  if not exists (select 1 from orgs where id = p_org) then raise exception 'Business not found.'; end if;
  select * into s from einvoice_settings where org_id = p_org;
  v_ready := private.einvoice_readiness(p_org);
  return jsonb_build_object('started', s.org_id is not null, 'enabled', coalesce(s.enabled, false), 'enabled_at', s.enabled_at,
    'platform_keys', coalesce(s.platform_keys, false), 'platform_keys_note', s.platform_keys_note,
    'own', jsonb_build_object('business_id', s.business_id is not null, 'service_id', s.service_id is not null, 'api_key', s.api_key_ct is not null,
      'api_secret', s.api_secret_ct is not null, 'crypto_keys', s.crypto_ct is not null),
    'check', case when s.checked_at is null then null else jsonb_build_object('at', s.checked_at, 'ok', s.check_ok, 'note', s.check_note,
      'current', s.check_version = s.keys_version) end,
    'ready', not exists (select 1 from jsonb_array_elements(v_ready) r where (r->>'blocking')::boolean and not (r->>'ok')::boolean),
    'readiness', (select coalesce(jsonb_agg(jsonb_build_object('id', r->>'id', 'ok', (r->>'ok')::boolean, 'blocking', (r->>'blocking')::boolean, 'title', r->>'title',
      'counts', r->'counts')), '[]'::jsonb) from jsonb_array_elements(v_ready) r));
end $$;

-- While NRS is in test mode, a business can run on TaxStreem's provider keys (the QA business for the demo, a business
-- trying it before it has its own). Switching either way needs a new NRS test, so e-invoicing goes off until it passes.
create or replace function public.admin_einvoice_platform_keys(p_org uuid, p_on boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, private as $$
declare v_new uuid;
begin
  perform private.require_staff();
  if not exists (select 1 from orgs where id = p_org) then raise exception 'Business not found.'; end if;
  if p_on is null then raise exception 'Choose on or off.'; end if;
  insert into einvoice_settings (org_id, updated_by) values (p_org, auth.uid()) on conflict (org_id) do nothing returning org_id into v_new;
  update einvoice_settings set platform_keys = p_on, platform_keys_note = nullif(left(btrim(coalesce(p_note, '')), 300), ''),
    keys_version = keys_version + case when platform_keys is distinct from p_on then 1 else 0 end,
    enabled = case when platform_keys is distinct from p_on then false else enabled end,
    updated_at = now(), updated_by = auth.uid()
  where org_id = p_org;
  perform private.audit('einvoice_platform_keys', p_org::text, jsonb_build_object('on', p_on, 'note', nullif(btrim(coalesce(p_note, '')), '')));
  if v_new is not null then perform private.call_function('ai', jsonb_build_object('action', 'nrs_codes_pending')); end if;
  return public.admin_einvoice_business(p_org);
end $$;

-- ---------------------------------------------------------------------------
-- 11. Who may call what
-- ---------------------------------------------------------------------------
revoke all on function public.nrs_code_search(text, text, int), public.set_item_hs_code(uuid, text, text), public.recheck_item_hs_code(uuid),
  public.einvoice_settings_get(uuid), public.einvoice_settings_set(uuid, jsonb), public.admin_einvoice_business(uuid),
  public.admin_einvoice_platform_keys(uuid, boolean, text), public.save_customer(uuid, jsonb) from public, anon;
grant execute on function public.nrs_code_search(text, text, int), public.set_item_hs_code(uuid, text, text), public.recheck_item_hs_code(uuid),
  public.einvoice_settings_get(uuid), public.einvoice_settings_set(uuid, jsonb), public.admin_einvoice_business(uuid),
  public.admin_einvoice_platform_keys(uuid, boolean, text), public.save_customer(uuid, jsonb) to authenticated;
revoke all on function public.svc_items_for_hs(int), public.svc_nrs_codes_under(text, text, int), public.svc_set_item_hs(uuid, jsonb),
  public.svc_orgs_for_service_code(int), public.svc_set_service_code(uuid, jsonb), public.svc_einvoice_keys_save(uuid, uuid, jsonb),
  public.svc_einvoice_check_begin(uuid), public.svc_einvoice_check_done(uuid, int, uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.svc_items_for_hs(int), public.svc_nrs_codes_under(text, text, int), public.svc_set_item_hs(uuid, jsonb),
  public.svc_orgs_for_service_code(int), public.svc_set_service_code(uuid, jsonb), public.svc_einvoice_keys_save(uuid, uuid, jsonb),
  public.svc_einvoice_check_begin(uuid), public.svc_einvoice_check_done(uuid, int, uuid, boolean, text) to service_role;
revoke all on function private.nrs_place(text, text), private.on_postcode_saved(), private.einvoice_viewer(uuid), private.nrs_code_ok(text, text),
  private.nrs_label(text, text), private.hs_code(text), private.words_and(text[]), private.on_item_renamed_hs(), private.einvoice_readiness(uuid), private.nrs_irn(text, text, date),
  private.einvoice_tick() from public, anon, authenticated;
