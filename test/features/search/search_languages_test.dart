import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';

/// A title, a query, and whether the title answers it.
typedef _Case = (String kind, String title, String query, bool answers);

/// The 2026-10 survey of search across languages: 206 cases, of which the
/// matcher before got 155 wrong. These are the 194 it now gets right; the
/// other 12 are [_limits]. Characters a reader can't see, or can't tell from
/// ASCII, are written as escapes.
const _cases = <_Case>[
  // ---- Arabic
  ('AR harakat', 'مُسَلْسَل وَادِي الذِّئَاب', 'وادي الذئاب', true),
  ('AR harakat', 'فِيلْم الرِّسَالَة', 'الرسالة', true),
  ('AR harakat', 'رِحْلَةُ البَحْرِ', 'رحلة البحر', true),
  ('AR harakat', 'مسلسل محمّد رسول الله', 'محمد رسول الله', true),
  ('AR alef', 'مسلسل قيامة أرطغرل', 'قيامة ارطغرل', true),
  ('AR alef', 'مسلسل قيامة ارطغرل', 'قيامة أرطغرل', true),
  ('AR alef', 'فيلم إكس لارج', 'اكس لارج', true),
  ('AR alef', 'مسلسل آسر', 'اسر', true),
  ('AR alef', 'فيلم ٱلرسالة', 'الرسالة', true),
  ('AR teh/heh', 'مسلسل الحفرة', 'الحفره', true),
  ('AR teh/heh', 'مسلسل الحفره الموسم 4', 'الحفرة', true),
  ('AR yeh', 'مسلسل فى بيتنا روبوت', 'في بيتنا روبوت', true),
  ('AR yeh', 'فيلم على معزة وإبراهيم', 'علي معزة', true),
  ('AR tatweel', 'مسلســل الطائر الرفراف', 'مسلسل الطائر الرفراف', true),
  ('AR tatweel', 'فيلـم الممر', 'فيلم الممر', true),
  ('AR digits', 'فيلم الفيل الأزرق ٢', 'الفيل الأزرق 2', true),
  ('AR digits', 'مسلسل الاختيار 3', 'الاختيار ٣', true),
  ('AR clitic', 'توم وجيري', 'جيري', true),
  ('AR clitic', 'رحلة البحر', 'بحر', true),
  ('AR clitic', 'قيس وليلى', 'ليلى', true),
  ('AR clitic', 'فيلم الحرب والسلام', 'السلام', true),
  (
    'AR control',
    'مسلسل هذا البحر سوف يفيض الحلقة 1 مترجمة',
    'هذا البحر سوف يفيض',
    true,
  ),
  ('AR control', 'مسلسل الحب الأعمى', 'الحفرة', false),
  // ---- Persian, Urdu
  ('FA yeh/kaf', 'سریال بازی مرکب', 'بازي مركب', true),
  ('FA yeh/kaf', 'سريال خانه كاغذي', 'خانه کاغذی', true),
  ('FA yeh/kaf', 'جدایی نادر از سیمین', 'جدايي نادر', true),
  ('FA yeh/kaf', 'میرے پاس تم ہو', 'ميرے پاس تم هو', true),
  ('FA yeh/kaf', 'تیرے بن', 'تيرے بن', true),
  ('FA yeh/kaf', 'کبھی میں کبھی تم', 'كبھي ميں', true),
  ('FA zwnj', 'بچه\u{200C}های آسمان', 'بچههای آسمان', true),
  ('FA zwnj', 'بچه\u{200C}های آسمان', 'بچه های آسمان', true),
  ('FA zwnj', 'بچه\u{200C}های آسمان', 'بچه\u{200C}های آسمان', true),
  ('FA digits', 'سریال شهرزاد فصل ۲', 'شهرزاد 2', true),
  ('FA digits', 'فیلم جوکر ۲۰۱۹', 'جوکر 2019', true),
  // ---- Hebrew
  ('HE niqqud', 'מָשָׁה וְהַדֹּב', 'משה והדב', true),
  ('HE niqqud', 'הַבּוֹרֵר', 'הבורר', true),
  ('HE geresh', 'ג׳וקר', "ג'וקר", true),
  ('HE geresh', 'ג׳וקר', 'גוקר', true),
  ('HE control', 'שטיסל', 'פאודה', false),
  // ---- Turkish, Azerbaijani
  ('TR dotless i', 'IŞIK', 'ışık', true),
  ('TR dotless i', 'Işıklar Sönmesin', 'ışıklar sönmesin', true),
  ('TR dotless i', 'Kızılcık Şerbeti', 'KIZILCIK ŞERBETİ', true),
  ('TR dotless i', 'İstanbullu Gelin', 'istanbullu gelin', true),
  ('TR ascii', 'Kuruluş: Osman', 'kurulus osman', true),
  ('TR ascii', 'Diriliş: Ertuğrul', 'dirilis ertugrul', true),
  ('TR ascii', 'Yalı Çapkını', 'yali capkini', true),
  ('TR ascii', 'Tasacak Bu Deniz', 'taşacak bu deniz', true),
  ('TR ascii', 'Çukur', 'cukur', true),
  ('TR ascii', 'Sen Çal Kapımı', 'sen cal kapimi', true),
  ('TR ascii', 'Aşk-ı Memnu', 'aski memnu', true),
  ('TR ascii', 'Bəxt Üzüyü', 'bext uzuyu', true),
  ('TR control', 'Kara Sevda', 'kara para aşk', false),
  // ---- German
  ('DE umlaut', 'Die Fälscher', 'die falscher', true),
  ('DE umlaut', 'Fack ju Göhte', 'fack ju gohte', true),
  ('DE umlaut', 'Türkisch für Anfänger', 'turkisch fur anfanger', true),
  ('DE eszett', 'Großstadtrevier', 'grossstadtrevier', true),
  (
    'DE eszett',
    'Die Straßen von San Francisco',
    'strassen von san francisco',
    true,
  ),
  ('DE ae/oe/ue', 'Fack ju Göhte', 'fack ju goehte', true),
  ('DE ae/oe/ue', 'Männerherzen', 'maennerherzen', true),
  // ---- French, Spanish, Portuguese, Italian, Polish, Czech, Nordic
  (
    'LAT accents',
    "Le Fabuleux Destin d'Amélie Poulain",
    'amelie poulain',
    true,
  ),
  ('LAT accents', 'Les Misérables', 'les miserables', true),
  ('LAT accents', 'Léon', 'leon', true),
  (
    'LAT accents',
    'Astérix & Obélix : Mission Cléopâtre',
    'asterix obelix mission cleopatre',
    true,
  ),
  ('LAT accents', 'Pokémon: The Movie 2000', 'pokemon', true),
  ('LAT accents', 'Pokemon Journeys', 'pokémon', true),
  ('LAT accents', 'El Señor de los Cielos', 'el senor de los cielos', true),
  ('LAT accents', 'Élite', 'elite', true),
  ('LAT accents', 'Y tu mamá también', 'y tu mama tambien', true),
  ('LAT accents', 'Narcos: México', 'narcos mexico', true),
  ('LAT accents', 'Pasión de Gavilanes', 'pasion de gavilanes', true),
  ('LAT accents', 'Minha Mãe é uma Peça', 'minha mae e uma peca', true),
  ('LAT accents', 'Bom Dia, Verônica', 'bom dia veronica', true),
  ('LAT accents', 'Ninguém Tá Olhando', 'ninguem ta olhando', true),
  ('LAT accents', 'La vita è bella', 'la vita e bella', true),
  ('LAT accents', 'Tutto può succedere', 'tutto puo succedere', true),
  ('LAT accents', 'Wiedźmin', 'wiedzmin', true),
  ('LAT accents', 'Ślepnąc od świateł', 'slepnac od swiatel', true),
  ('LAT accents', 'Tři oříšky pro Popelku', 'tri orisky pro popelku', true),
  ('LAT accents', 'Pelíšky', 'pelisky', true),
  ('LAT letters', 'Boże Ciało', 'boze cialo', true),
  ('LAT letters', 'Chłopi', 'chlopi', true),
  ('LAT letters', 'Bølgen', 'bolgen', true),
  ('LAT letters', 'Ófærð', 'ofaerd', true),
  ('LAT letters', 'Hævnen', 'haevnen', true),
  ('LAT nfd', 'Poke\u{301}mon Horizons', 'pokémon', true),
  ('LAT nfd', 'Poke\u{301}mon Horizons', 'pokemon', true),
  ('LAT nfd', 'Les Mise\u{301}rables', 'les misérables', true),
  ('LAT nfd', 'Pokémon Horizons', 'Poke\u{301}mon', true),
  // ---- Vietnamese
  ('VI', 'Bố Già', 'bo gia', true),
  ('VI', 'Tây Du Ký', 'tay du ky', true),
  ('VI', 'Đất Rừng Phương Nam', 'dat rung phuong nam', true),
  ('VI', 'Lật Mặt 7: Một Điều Ước', 'lat mat 7', true),
  ('VI', 'Nhà Bà Nữ', 'nha ba nu', true),
  ('VI', 'Mắt Biếc', 'mat biec', true),
  ('VI nfd', 'Ma\u{306}\u{301}t Bie\u{302}\u{301}c', 'mắt biếc', true),
  // ---- Greek
  ('EL tonos', 'Άγριες Μέλισσες', 'αγριες μελισσες', true),
  ('EL tonos', 'Κυνόδοντας', 'κυνοδοντας', true),
  ('EL tonos', 'Το Νησί', 'το νησι', true),
  ('EL tonos', 'Σασμός', 'σασμος', true),
  ('EL sigma', 'ΑΓΡΙΕΣ ΜΕΛΙΣΣΕΣ', 'άγριες μέλισσες', true),
  ('EL sigma', 'ΟΔΥΣΣΕΑΣ', 'οδυσσεας', true),
  // ---- Cyrillic
  ('CY yo', 'Чёрное зеркало', 'черное зеркало', true),
  ('CY yo', 'Ёлки 2', 'елки 2', true),
  ('CY yo', 'Зелёная миля', 'зеленая миля', true),
  ('CY yo', 'Пёс', 'пес', true),
  (
    'CY nfd',
    'Мои\u{306} ласковыи\u{306} и нежныи\u{306} зверь',
    'мой ласковый',
    true,
  ),
  ('CY apostrophe', 'Моя сім\u{2BC}я', "сім'я", true),
  ('CY control', 'Мастер и Маргарита', 'мастер и маргарита', true),
  // ---- Indic
  ('IN control', 'दंगल', 'दंगल', true),
  ('IN control', 'पुष्पा 2: द रूल', 'पुष्पा', true),
  ('IN control', 'बाहुबली 2: द कन्क्लूज़न', 'बाहुबली', true),
  ('IN control', 'పుష్ప 2: ది రూల్', 'పుష్ప', true),
  ('IN control', 'ಕೆಜಿಎಫ್ ಚಾಪ್ಟರ್ 2', 'ಕೆಜಿಎಫ್', true),
  ('IN control', 'পথের পাঁচালী', 'পাঁচালী', true),
  ('IN shredding', 'तारे ज़मीन पर', 'मिर्ज़ापुर', false),
  ('IN shredding', 'ஜெயிலர்', 'லியோ', false),
  ('IN shredding', 'दंगल', 'गली', false),
  ('IN shredding', 'द फैमिली मैन', 'दिल', false),
  ('IN shredding', 'ಕಾಂತಾರ', 'ಕಿರಿಕ್', false),
  ('IN digits', 'स्कैम १९९२', 'स्कैम 1992', true),
  ('IN two-part vowel', 'பொன்னியின் செல்வன்', 'பொன்னியின் செல்வன்', true),
  ('IN two-part vowel', 'കൊറോണ പേപ്പേഴ്സ്', 'കൊറോണ', true),
  ('IN variant', 'हिन्दी मीडियम', 'हिंदी मीडियम', true),
  ('IN variant', 'ज़िंदगी ना मिलेगी दोबारा', 'जिंदगी ना मिलेगी दोबारा', true),
  ('IN variant', 'फँड्री', 'फंड्री', true),
  ('IN variant', 'ਸੁਫ਼ਨਾ', 'ਸੁਫਨਾ', true),
  ('ML chillu', 'മഞ്ഞുമ്മല്\u{200D} ബോയ്സ്', 'മഞ്ഞുമ്മൽ ബോയ്സ്', true),
  ('ML chillu', 'മഞ്ഞുമ്മൽ ബോയ്സ്', 'മഞ്ഞുമ്മല്\u{200D}', true),
  // ---- Thai
  ('TH', 'พี่มากพระโขนง', 'พระโขนง', true),
  ('TH', 'ฉลาดเกมส์โกง', 'เกมส์โกง', true),
  ('TH', 'ร่างทรง', 'ร่าง', true),
  ('TH', 'หลานม่า', 'หลาน', true),
  ('TH', 'ชัตเตอร์ กดติดวิญญาณ', 'กดติดวิญญาณ', true),
  ('TH', 'แปลรักฉันด้วยใจเธอ', 'ใจเธอ', true),
  // ---- Chinese, Japanese
  ('ZH substring', '哪吒之魔童降世', '魔童', true),
  ('ZH substring', '哪吒之魔童降世', '哪吒', true),
  ('ZH substring', '庆余年第二季', '庆余年', true),
  ('ZH substring', '庆余年第二季', '第二季', true),
  ('ZH substring', '哈利·波特与魔法石', '哈利波特', true),
  ('ZH substring', '哈利\u{2027}波特：神秘的魔法石', '哈利波特', true),
  ('ZH width', '流浪地球２', '流浪地球2', true),
  ('ZH trad/simp', '慶餘年 第二季', '庆余年', true),
  ('ZH trad/simp', '甄嬛傳', '甄嬛传', true),
  ('JA substring', '名探偵コナン 黒鉄の魚影', 'コナン', true),
  ('JA substring', '葬送のフリーレン', 'フリーレン', true),
  ('JA substring', '鬼滅の刃 遊郭編', '刃', true),
  ('JA substring', '鬼滅の刃 遊郭編', '鬼滅', true),
  ('JA substring', '進撃の巨人 The Final Season', '巨人', true),
  ('JA substring', 'ハリー・ポッターと賢者の石', 'ハリーポッター', true),
  ('JA substring', '千と千尋の神隠し', '千尋', true),
  ('JA substring', '君の名は。', '君の名は', true),
  ('JA width', 'ＳＰＹ×ＦＡＭＩＬＹ', 'spy family', true),
  ('JA width', 'ｽﾊﾟｲﾌｧﾐﾘｰ', 'スパイファミリー', true),
  ('JA nfd', '機動戦士カ\u{3099}ンダム', 'ガンダム', true),
  ('JA control', 'ドラえもん', 'コナン', false),
  // ---- Korean
  ('KO spacing', '오징어 게임', '오징어게임', true),
  ('KO spacing', '오징어게임 시즌2', '오징어 게임', true),
  ('KO spacing', '눈물의 여왕', '눈물의여왕', true),
  ('KO spacing', '선재 업고 튀어', '선재업고튀어', true),
  ('KO control', '사랑의 불시착', '불시착', true),
  ('KO control', '이상한 변호사 우영우', '우영우', true),
  ('KO control', '기생충', '오징어', false),
  // ---- apostrophes, hyphens, dots, ligatures, zero-width
  ('PUNCT joined', "Grey's Anatomy", 'greys anatomy', true),
  ('PUNCT joined', "Ocean's Eleven", 'oceans eleven', true),
  ('PUNCT joined', "Schindler's List", 'schindlers list', true),
  ('PUNCT joined', 'Spider-Man: No Way Home', 'spiderman no way home', true),
  (
    'PUNCT joined',
    'X-Men: Days of Future Past',
    'xmen days of future past',
    true,
  ),
  ('PUNCT joined', 'WALL·E', 'walle', true),
  ('PUNCT joined', "Marvel's Agents of S.H.I.E.L.D.", 'agents of shield', true),
  ('PUNCT joined', 'E.T. the Extra-Terrestrial', 'et extraterrestrial', true),
  ('PUNCT joined', "Bienvenue chez les Ch'tis", 'chtis', true),
  ('PUNCT joined', "L'amica geniale", 'lamica geniale', true),
  ('PUNCT joined', 'Hawai\u{2BB}i Five-0', 'hawaii five 0', true),
  ('PUNCT quotes', 'Grey\u{2019}s Anatomy', "grey's anatomy", true),
  ('PUNCT quotes', 'Grey\u{2BC}s Anatomy', "grey's anatomy", true),
  ('PUNCT quotes', "L'amica geniale", 'amica geniale', true),
  ('LIG', "L'Arnacœur", 'arnacoeur', true),
  ('LIG', 'Æon Flux', 'aeon flux', true),
  ('LIG', 'The Pro\u{FB01}le', 'profile', true),
  ('ZW', 'Bridg\u{AD}erton', 'bridgerton', true),
  ('ZW', 'Stran\u{200B}ger Things', 'stranger things', true),
  ('ZW', 'Breaking\u{200B} Bad', 'breaking bad', true),
  // ---- cross-script: the site answered in another script. A title alone
  // can't show it; the three that answer are known limits, kept with the
  // rest of their answer (see 'answers in other scripts' below).
  ('XSCRIPT', 'Legend of the Blue Sea', 'هذا البحر سوف يفيض', false),
  // ---- master's own tests and intended non-matches
  ('CONTROL', 'His Girl Friday (1940)', 'his girl friday 1940', true),
  ('CONTROL', 'Night of the Living Dead', 'dead night', true),
  ('CONTROL', 'Night of the Living Dead', 'ight', false),
  ('CONTROL', 'Night of the Living Dead', 'night zombie', false),
  ('CONTROL', 'Batman Begins', 'man', false),
  ('CONTROL', 'Superman', 'man', false),
  ('CONTROL', 'Pokémon: The Movie 2000', 'pokémon 2000', true),
  ('CONTROL', 'Spider-Man: No Way Home', 'spider man', true),
  ('CONTROL', 'Spider-Man: No Way Home', 'spider-man', true),
  ('CONTROL', 'Spider Man No Way Home', 'spider-man no way home', true),
  ('CONTROL', 'The Batman', 'batman', true),
];

/// A survey case the matcher gets wrong, what it does, and why.
typedef _Limit = (
  String kind,
  String title,
  String query,
  bool matches,
  String why,
);

/// The survey cases the matcher gets wrong: costs of its rules, and
/// differences no rule here can see. Each is checked for what the matcher
/// does, so a change that fixes one shows.
const _limits = <_Limit>[
  (
    'AR control',
    'مسلسل وادي الذئاب',
    'ادي',
    true,
    'a word of four letters or more loses a leading و, read as "and"',
  ),
  (
    'AR wording',
    'مسلسل هذا البحر سيفيض',
    'هذا البحر سوف يفيض',
    false,
    'another wording (سيفيض for سوف يفيض), which no spelling rule reaches',
  ),
  (
    'FA zwnj',
    'بچههای آسمان',
    'بچه\u{200C}های آسمان',
    false,
    "the query's ZWNJ splits a word the title writes as one; joined forms are made for titles only",
  ),
  (
    'DE ae/oe/ue',
    'Fack ju Goehte',
    'fack ju göhte',
    false,
    'ae/oe/ue spellings are made for titles only, so a title written with oe is not found by ö',
  ),
  (
    'DE control',
    'Schon wieder Sommer',
    'schön',
    true,
    'umlauts fold to the plain vowel',
  ),
  ('LAT control', 'Pena máxima', 'peña', true, 'ñ folds to n'),
  (
    'VI control',
    'Bộ Tứ Siêu Đẳng',
    'bố',
    true,
    'Vietnamese tone marks fold away',
  ),
  ('CY control', 'Мой ласковый и нежный зверь', 'мои', true, 'й folds to и'),
  (
    'PUNCT joined',
    'Spiderman 3',
    'spider-man 3',
    false,
    "the query's hyphen splits it, and no title word begins with man",
  ),
  (
    'XSCRIPT',
    'Tasacak Bu Deniz',
    'هذا البحر سوف يفيض',
    false,
    'another script; the rule for a whole answer in other scripts keeps it',
  ),
  (
    'XSCRIPT',
    'Demon Slayer: Kimetsu no Yaiba',
    '鬼滅の刃',
    false,
    'another script; the rule for a whole answer in other scripts keeps it',
  ),
  (
    'XSCRIPT',
    'Squid Game',
    '오징어 게임',
    false,
    'another script; the rule for a whole answer in other scripts keeps it',
  ),
];

/// Real titles from providers' home pages in the survey, each with the
/// query of someone typing without accents, hamza or apostrophes.
const _realTitles = <(String kind, String title, String query)>[
  (
    'no-apostrophe',
    "A Gatherer's Adventure in Isekai",
    'A Gatherers Adventure in Isekai',
  ),
  (
    'no-apostrophe',
    "As a Reincarnated Aristocrat, I'll",
    'As a Reincarnated Aristocrat, Ill',
  ),
  (
    'no-apostrophe',
    'As a Reincarnated Aristocrat, I`ll',
    'As a Reincarnated Aristocrat, Ill',
  ),
  ('no-apostrophe', 'Assassin\u{2019}s Creed', 'Assassins Creed'),
  ('no-accents', 'Basta Mamá', 'Basta Mama'),
  ('no-accents', 'El hombre que desafió al', 'El hombre que desafio al'),
  (
    'no-apostrophe',
    'Frieren: Beyond Journey\u{2019}s End',
    'Frieren: Beyond Journeys End',
  ),
  (
    'no-apostrophe',
    'How to Draw: A Beginner\u{2019}s',
    'How to Draw: A Beginners',
  ),
  (
    'no-apostrophe',
    "I'm pregnant, it's not yours",
    'Im pregnant, its not yours',
  ),
  ('no-apostrophe', 'India\u{2019}s Got Latent', 'Indias Got Latent'),
  ('no-apostrophe', "JoJo's Bizarre Adventure", 'JoJos Bizarre Adventure'),
  (
    'no-apostrophe',
    'JoJo\u{2019}s Bizarre Adventure Season 3',
    'JoJos Bizarre Adventure Season 3',
  ),
  (
    'no-accents',
    'Kasımpaşa SK vs. Galatasaray SK',
    'Kasimpasa SK vs. Galatasaray SK',
  ),
  ('no-apostrophe', 'La Pat\u{2019} Patrouille : Le', 'La Pat Patrouille : Le'),
  (
    'no-accents',
    'Mononoke – O Filme: Capítulo',
    'Mononoke – O Filme: Capitulo',
  ),
  (
    'no-accents',
    'Paw Patrol: La dino película',
    'Paw Patrol: La dino pelicula',
  ),
  ('no-accents', 'Pokémon: FireRed Version', 'Pokemon: FireRed Version'),
  (
    'no-apostrophe',
    'Rocky JoJo\u{2019}s Bizarre Adventure Season',
    'Rocky JoJos Bizarre Adventure Season',
  ),
  ('no-accents', 'Spider-Man: Un nuevo día', 'Spider-Man: Un nuevo dia'),
  ('no-apostrophe', "The Crown I'll Claim", 'The Crown Ill Claim'),
  (
    'no-apostrophe',
    "Virginia Woolf's Night & Day",
    'Virginia Woolfs Night & Day',
  ),
  (
    'no-apostrophe',
    'Virginia Woolf\u{2019}s Night & Day',
    'Virginia Woolfs Night & Day',
  ),
  ('no-hamza', 'أشياء غريبة حكايات من عام', 'اشياء غريبة حكايات من عام'),
  ('heh-for-teh', 'أشياء غريبة حكايات من عام', 'أشياء غريبه حكايات من عام'),
  (
    'no-hamza',
    'ألتيميت سبايدرمان الموسم الثاني',
    'التيميت سبايدرمان الموسم الثاني',
  ),
  ('heh-for-teh', 'المهمة السرية: طائر السنونو', 'المهمه السريه: طائر السنونو'),
  (
    'heh-for-teh',
    'مسلسل Medusa الموسم الثاني الحلقة',
    'مسلسل Medusa الموسم الثاني الحلقه',
  ),
  (
    'heh-for-teh',
    'مسلسل القهوة المالحة الحلقة 5',
    'مسلسل القهوه المالحه الحلقه 5',
  ),
  (
    'heh-for-teh',
    'مسلسل القهوة المالحة الحلقة 6',
    'مسلسل القهوه المالحه الحلقه 6',
  ),
  ('heh-for-teh', 'مسلسل الكرامة الحلقة 4', 'مسلسل الكرامه الحلقه 4'),
  (
    'heh-for-teh',
    'مسلسل امنية وان تحققت الحلقة',
    'مسلسل امنيه وان تحققت الحلقه',
  ),
  ('no-hamza', 'مسلسل حياة الآخرين مترجمة', 'مسلسل حياة الاخرين مترجمة'),
  ('heh-for-teh', 'مسلسل حياة الآخرين مترجمة', 'مسلسل حياه الآخرين مترجمه'),
  (
    'heh-for-teh',
    'مشاهدة فيلم Drawn Together 2026',
    'مشاهده فيلم Drawn Together 2026',
  ),
  ('no-hamza', 'نبيل التنس الموسم الأول', 'نبيل التنس الموسم الاول'),
];

/// Titles of one script each: each is found by its full name, and no other
/// title is. The matcher before split Indic words at their vowel signs, so
/// "मिर्ज़ापुर" found "तारे ज़मीन पर".
const _scriptSets = <String, List<String>>{
  'Hindi': [
    'दंगल', 'शोले', 'दिलवाले दुल्हनिया ले जाएंगे', 'लगान', 'पठान', 'जवान', //
    'गदर 2', 'एनिमल', 'स्त्री 2', 'भूल भुलैया 3', 'कभी ख़ुशी कभी ग़म',
    'ज़िंदगी ना मिलेगी दोबारा', '3 इडियट्स', 'पीके', 'बजरंगी भाईजान',
    'तारे ज़मीन पर', 'हम आपके हैं कौन', 'कुछ कुछ होता है', 'मिर्ज़ापुर',
    'पंचायत', 'सेक्रेड गेम्स', 'द फैमिली मैन', 'स्कैम 1992', 'गुल्लक',
    'कोटा फैक्ट्री', 'दिल चाहता है', 'दिल से', 'देवदास',
    'गंगूबाई काठियावाड़ी', 'चक दे! इंडिया', 'रंग दे बसंती', 'धूम 3', 'डॉन',
    'हेरा फेरी', 'अंदाज़ अपना अपना', 'क्वीन', 'बर्फ़ी!', 'हिंदी मीडियम',
    'दृश्यम 2', 'सुल्तान', 'दिल धड़कने दो', 'गली बॉय', 'सैराट', 'नटसम्राट',
  ],
  'Tamil': [
    'விக்ரம்', 'ஜெயிலர்', 'பொன்னியின் செல்வன்', 'மாஸ்டர்', 'லியோ', 'கைதி', //
    'அசுரன்', 'சூரரைப் போற்று', 'விடுதலை', 'ஜெய் பீம்', 'மகாராஜா', 'அமரன்',
  ],
  'Telugu': [
    'బాహుబలి', 'పుష్ప', 'ఆర్ ఆర్ ఆర్', 'అల వైకుంఠపురములో', 'సలార్', //
    'కల్కి 2898 ఏడీ', 'దేవర', 'హనుమాన్', 'అర్జున్ రెడ్డి', 'మహానటి',
  ],
  'Kannada': [
    'ಕಾಂತಾರ',
    'ಕೆಜಿಎಫ್',
    'ಚಾರ್ಲಿ 777',
    'ಕಿರಿಕ್ ಪಾರ್ಟಿ',
    'ಮುಂಗಾರು ಮಳೆ',
    'ಯು ಟರ್ನ್', //
  ],
  'Malayalam': [
    'ദൃശ്യം', 'മഞ്ഞുമ്മൽ ബോയ്സ്', 'പ്രേമലു', 'ആവേശം', 'ലൂസിഫർ', //
    'കുമ്പളങ്ങി നൈറ്റ്സ്', 'ഭ്രമയുഗം', 'മിന്നൽ മുരളി',
  ],
  'Bengali': [
    'পথের পাঁচালী', 'চারুলতা', 'মেঘে ঢাকা তারা', 'অপুর সংসার', //
    'হীরক রাজার দেশে', 'সোনার কেল্লা', 'ব্যোমকেশ', 'মনপুরা',
  ],
  'Gurmukhi': [
    'ਕੈਰੀ ਆਨ ਜੱਟਾ', 'ਚੱਲ ਮੇਰਾ ਪੁੱਤ', 'ਜੱਟ ਐਂਡ ਜੂਲੀਅਟ', 'ਅੰਗਰੇਜ', 'ਸੁਫ਼ਨਾ', //
    'ਹੌਂਸਲਾ ਰੱਖ',
  ],
  'Gujarati': [
    'હેલ્લારો', 'છેલ્લો દિવસ', 'ગુજ્જુભાઈ ધ ગ્રેટ', 'રેવા', '21મું ટિફિન', //
    'ચાલ જીવી લઈએ!',
  ],
  'Thai': [
    'ฉลาดเกมส์โกง', 'พี่มากพระโขนง', 'ร่างทรง', 'หลานม่า', 'บุพเพสันนิวาส', //
    'แปลรักฉันด้วยใจเธอ', 'เพราะเราคู่กัน', 'ต้มยำกุ้ง', 'องค์บาก',
    'ชัตเตอร์ กดติดวิญญาณ', 'สัปเหร่อ', 'ธี่หยด', 'แฟนฉัน',
    'รถไฟฟ้า มาหานะเธอ', 'คิดถึงวิทยา', 'ฮาวทูทิ้ง ทิ้งอย่างไรไม่ให้เหลือเธอ',
  ],
};

void main() {
  group('survey cases', () {
    for (final (kind, title, query, answers) in _cases) {
      test('$kind: "$title" ${answers ? 'answers' : 'does not answer'} '
          '"$query"', () {
        expect(titleMatches(title, searchWords(query)), answers);
      });
    }
  });

  group('known limits', () {
    for (final (kind, title, query, matches, why) in _limits) {
      test('$kind: "$title" ${matches ? 'matches' : 'misses'} "$query": '
          '$why', () {
        expect(titleMatches(title, searchWords(query)), matches);
      });
    }
  });

  group('answers in other scripts', () {
    // A provider's answer with no title in a script of the query is kept
    // whole (issue #36), whether each title answers the query or not.
    for (final (title, query, answers) in const [
      ('Tasacak Bu Deniz', 'هذا البحر سوف يفيض', true),
      ('Demon Slayer: Kimetsu no Yaiba', '鬼滅の刃', true),
      ('Squid Game', '오징어 게임', true),
      ('Legend of the Blue Sea', 'هذا البحر سوف يفيض', false),
    ]) {
      test(
        '"$title" alone, for "$query", is kept'
        '${answers ? '' : ', though it does not answer it (known limit)'}',
        () {
          expect(answeredInOtherScripts([title], searchWords(query)), isTrue);
        },
      );
    }
  });

  group('real titles', () {
    for (final (kind, title, query) in _realTitles) {
      test('$kind: "$title" answers "$query"', () {
        expect(titleMatches(title, searchWords(query)), isTrue);
      });
    }
  });

  group('titles of one script', () {
    for (final MapEntry(key: script, value: titles) in _scriptSets.entries) {
      test('$script: each title is found by its full name, and no other '
          'is', () {
        for (final query in titles) {
          final found = [
            for (final title in titles)
              if (titleMatches(title, searchWords(query))) title,
          ];
          expect(found, [query], reason: 'searching "$query"');
        }
      });

      test('$script: each title is found by any of its words typed up to any '
          'of its characters', () {
        // A fold that looks ahead (a Hindi nasal and virama before a
        // consonant as an anusvara) must not lose the words typed so far.
        final missed = <String>[];
        for (final title in titles) {
          for (final word in title.split(' ')) {
            final characters = word.runes.toList();
            for (var length = 1; length <= characters.length; length++) {
              final typed = String.fromCharCodes(characters.take(length));
              if (!titleMatches(title, searchWords(typed))) {
                missed.add('"$typed" in "$title"');
              }
            }
          }
        }
        expect(missed, isEmpty);
      });
    }
  });
}
