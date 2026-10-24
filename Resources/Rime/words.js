/* La Rime : les familles de rimes (en français) et les phrases du jeu.
   Une famille = une terminaison qu'on entend ; `ends` rattache aussi les mots qui ne sont pas dans la liste ; `vow` regroupe les familles qui
   partagent la même voyelle finale (assonance : on garde, mais pour moins de points). Les phrases finissent toutes par un mot de leur famille. */
const FAMILIES = [
  { id: 'ion', vow: 'ɔ̃', ends: ['ions?$'], words: ['nation', 'passion', 'émotion', 'attention', 'vision', 'mission', 'version', 'direction', 'création', 'tradition', 'illusion', 'solution', 'révolution', 'pression', 'sensation', 'relation', 'situation', 'imagination', 'inspiration', 'explosion', 'ambition', 'lion', 'avion', 'million'] },
  { id: 'é', ends: ['(é|ée|ées|és|er|ers|ez|ier|iers)$'], words: ['été', 'clarté', 'liberté', 'beauté', 'vérité', 'année', 'fumée', 'journée', 'pensée', 'idée', 'soirée', 'armée', 'danser', 'rêver', 'aimer', 'chanter', 'passé', 'oublié', 'nuée', 'café', 'marché', 'parler', 'marcher', 'briller', 'durer'] },
  { id: 'è', ends: ['(ais|ait|aient|et|ets|êt|ai)$'], words: ['jamais', 'mais', 'secret', 'projet', 'regret', 'forêt', 'reflet', 'objet', 'sujet', 'filet', 'souhait', 'parfait', 'succès', 'progrès', 'accès', 'après', 'près', 'trait', 'fait', 'vrai', 'essai', 'balai', 'délai', 'ballet', 'chalet'] },
  { id: 'ou', ends: ['(ou|oux|oup|oups|oût|outs)$'], words: ['fou', 'tout', 'doux', 'genou', 'partout', 'loup', 'coup', 'bijou', 'nous', 'vous', 'jaloux', 'dessous', 'debout', 'caillou', 'chou', 'joujou', 'mou', 'trou', 'cou', 'sou', 'goût', 'août', 'bout', 'remous', 'époux', 'filou', 'hibou', 'verrou'] },
  { id: 'our', ends: ['(our|ours|ourd|ourt)$'], words: ['amour', 'jour', 'toujours', 'retour', 'tour', 'séjour', 'contour', 'velours', 'humour', 'tambour', 'parcours', 'secours', 'discours', 'détour', 'lourd', 'sourd', 'court', 'cour', 'four', 'pour'] },
  { id: 'eur', ends: ['(eur|eurs|œur|œurs|eure|eures)$'], words: ['cœur', 'peur', 'bonheur', 'douleur', 'chaleur', 'couleur', 'lueur', 'sueur', 'erreur', 'valeur', 'fleur', 'heure', 'meilleur', 'pleur', 'rumeur', 'horreur', 'labeur', 'rancœur', 'vainqueur', 'chanteur', 'rappeur', 'danseur', 'auteur', 'moteur'] },
  { id: 'ant', vow: 'ɑ̃', ends: ['(ant|ants|ans|emps|amp|ands?|ang|anc)$'], words: ['temps', 'vent', 'chant', 'enfant', 'instant', 'moment', 'vraiment', 'sentiment', 'maintenant', 'battant', 'tellement', 'souvent', 'gens', 'dedans', 'longtemps', 'brillant', 'comment', 'lentement', 'innocent', 'présent', 'absent', 'content', 'argent', 'dent', 'sang', 'blanc', 'banc', 'rang', 'flanc', 'champ', 'camp', 'grand', 'quand'] },
  { id: 'in', ends: ['(in|ins|ain|ains|ein|eins|ien|iens)$'], words: ['matin', 'chemin', 'main', 'demain', 'soudain', 'destin', 'lointain', 'serein', 'vain', 'rien', 'bien', 'chien', 'gamin', 'jardin', 'bassin', 'cousin', 'voisin', 'vin', 'fin', 'faim', 'plein', 'sein', 'humain', 'certain', 'parrain', 'refrain', 'train', 'pain'] },
  { id: 'on', vow: 'ɔ̃', ends: ['(on|ons|ont|ond|onds|om)$'], words: ['maison', 'saison', 'raison', 'chanson', 'horizon', 'son', 'nom', 'bon', 'long', 'façon', 'garçon', 'poisson', 'démon', 'mon', 'ton', 'rond', 'profond', 'fond', 'pont', 'mont', 'monde', 'ballon', 'violon', 'crayon', 'blouson'] },
  { id: 'o', ends: ['(eau|eaux|au|aux)$'], words: ['eau', 'beau', 'tombeau', 'bateau', 'oiseau', 'nouveau', 'cadeau', 'château', 'flambeau', 'rideau', 'ruisseau', 'marteau', 'couteau', 'chapeau', 'tableau', 'gâteau', 'niveau', 'drapeau', 'troupeau', 'bureau', 'panneau', 'héros', 'trop', 'dos', 'mot', 'gros', 'repos', 'propos', 'chaos', 'haut', 'tôt', 'aussitôt', 'bientôt', 'métro', 'idéo', 'vélo', 'photo', 'piano', 'stylo'] },
  { id: 'oi', ends: ['(oi|ois|oix|oit|oids|oie)$'], words: ['moi', 'toi', 'roi', 'loi', 'foi', 'quoi', 'pourquoi', 'voix', 'bois', 'fois', 'choix', 'mois', 'droit', 'endroit', 'étroit', 'froid', 'doigt', 'effroi', 'émoi', 'paroi', 'croix', 'voie', 'joie', 'proie', 'soie'] },
  { id: 'oir', ends: ['(oir|oirs|oire|oires)$'], words: ['soir', 'noir', 'espoir', 'histoire', 'mémoire', 'victoire', 'gloire', 'miroir', 'pouvoir', 'avoir', 'savoir', 'devoir', 'boire', 'tiroir', 'couloir', 'trottoir', 'désespoir', 'rasoir', 'dortoir', 'comptoir', 'bonsoir'] },
  { id: 'ui', ends: ['(uit|uits|ui|uis|uie|uies)$'], words: ['nuit', 'bruit', 'fuit', 'suit', 'minuit', 'produit', 'poursuit', 'ennui', 'aujourd’hui', 'lui', 'puis', 'depuis', 'cuit', 'fruit', 'détruit', 'traduit', 'pluie', 'appui', 'conduit', 'huit', 'suite'] },
  { id: 'i', ends: ['(ie|ies|i|is|it|its|ix|ï)$'], words: ['vie', 'envie', 'folie', 'magie', 'mélodie', 'nostalgie', 'ironie', 'amie', 'partie', 'harmonie', 'ami', 'ennemi', 'ici', 'aussi', 'merci', 'midi', 'défi', 'ordi', 'parti', 'ravi', 'dit', 'lit', 'prix', 'souris', 'pays', 'esprit', 'avis', 'ami'] },
  { id: 'ir', ends: ['(ir|irs|irt|ire|ires)$'], words: ['partir', 'sentir', 'mourir', 'grandir', 'souvenir', 'choisir', 'plaisir', 'désir', 'venir', 'tenir', 'finir', 'pâlir', 'ressentir', 'courir', 'rire', 'dire', 'sourire', 'écrire', 'empire', 'délire', 'souffrir', 'frémir', 'dormir', 'offrir', 'réussir', 'agir'] },
  { id: 'ure', ends: ['(ur|urs|ure|ures|ûr|ûre)$'], words: ['mur', 'dur', 'pur', 'futur', 'azur', 'sûr', 'murmure', 'nature', 'aventure', 'blessure', 'voiture', 'lecture', 'culture', 'ceinture', 'obscur', 'mesure', 'armure', 'allure', 'figure', 'fissure'] },
  { id: 'ère', ends: ['(ère|ères|erre|erres|air|airs|aire|aires|ierre)$'], words: ['terre', 'guerre', 'lumière', 'frontière', 'mystère', 'chimère', 'poussière', 'rivière', 'prière', 'première', 'dernière', 'pierre', 'mère', 'père', 'frère', 'lierre', 'clair', 'air', 'mer', 'hiver', 'fer', 'enfer', 'éclair', 'fier', 'cher', 'amer', 'chair', 'galère', 'repère', 'sphère', 'atmosphère', 'carrière', 'misère', 'colère', 'manière'] },
  { id: 'ort', ends: ['(ort|orts|ord|ords|orps|ors)$'], words: ['mort', 'sort', 'fort', 'port', 'effort', 'accord', 'corps', 'dehors', 'trésor', 'or', 'encore', 'décor', 'bord', 'tort', 'ressort', 'confort', 'transport', 'réconfort', 'support', 'rapport', 'record', 'nord'] },
  { id: 'ar', ends: ['(ard|ards|art|arts|ar|ars)$'], words: ['regard', 'hasard', 'retard', 'brouillard', 'art', 'part', 'car', 'tard', 'bar', 'lard', 'rempart', 'départ', 'canular', 'bazar', 'nénuphar', 'poignard', 'cauchemar'] },
  { id: 'are', ends: ['(are|ares|arre|arres|ard?e)$'], words: ['gare', 'phare', 'bizarre', 'guitare', 'bagarre', 'fanfare', 'barbare', 'avare', 'rare', 'mare', 'barre', 'tiare', 'cigare'] },
  { id: 'elle', ends: ['(elle|elles|el|els|èle|èles)$'], words: ['belle', 'elle', 'fidèle', 'rebelle', 'ruelle', 'étincelle', 'chandelle', 'dentelle', 'tourterelle', 'ciel', 'miel', 'sel', 'réel', 'éternel', 'naturel', 'mortel', 'tunnel', 'nouvelle', 'hirondelle', 'modèle', 'appel', 'hôtel', 'rituel'] },
  { id: 'al', ends: ['(al|als|ale|ales|all|alle)$'], words: ['animal', 'final', 'idéal', 'normal', 'original', 'banal', 'brutal', 'régal', 'rival', 'signal', 'capital', 'métal', 'cheval', 'mal', 'bal', 'canal', 'total', 'fatal', 'capitale', 'vandale', 'radical', 'festival'] },
  { id: 'ile', ends: ['(ile|iles|il|ils)$'], words: ['ville', 'mille', 'tranquille', 'facile', 'île', 'utile', 'habile', 'mobile', 'fragile', 'agile', 'docile', 'civil', 'profil', 'avril', 'péril', 'subtil', 'gentil', 'outil', 'fusil', 'exil', 'style', 'pile', 'file', 'imbécile'] },
  { id: 'ille', ends: ['(aille|ailles|(?<!ou)ille|(?<!ou)illes)$'], words: ['famille', 'fille', 'brille', 'paille', 'bataille', 'grille', 'coquille', 'gentille', 'trille', 'médaille', 'muraille', 'taille', 'canaille', 'racaille', 'travaille', 'chandail', 'vaille', 'faille', 'pétille', 'scintille'] },
  { id: 'eil', ends: ['(eil|eils|eille|eilles|ei)$'], words: ['soleil', 'sommeil', 'réveil', 'merveille', 'oreille', 'abeille', 'pareil', 'éveil', 'conseil', 'vermeil', 'veille', 'bouteille', 'corbeille', 'treille', 'appareil', 'corneille', 'bouteille'] },
  { id: 'age', ends: ['(age|ages|âge|âges)$'], words: ['voyage', 'nuage', 'orage', 'visage', 'courage', 'paysage', 'image', 'sage', 'passage', 'plage', 'village', 'mirage', 'message', 'partage', 'rivage', 'héritage', 'bagage', 'ombrage', 'ouvrage', 'langage'] },
  { id: 'ange', vow: 'ɑ̃', ends: ['(ange|anges|anche|anches)$'], words: ['ange', 'étrange', 'change', 'frange', 'mélange', 'échange', 'orange', 'vendange', 'louange', 'phalange', 'dérange', 'grange', 'dimanche', 'manche', 'branche', 'hanche', 'revanche', 'avalanche'] },
  { id: 'ance', vow: 'ɑ̃', ends: ['(ance|ances|ence|ences|anse|anses)$'], words: ['danse', 'chance', 'silence', 'enfance', 'présence', 'cadence', 'patience', 'confiance', 'distance', 'absence', 'souffrance', 'espérance', 'évidence', 'transe', 'France', 'naissance', 'puissance', 'essence', 'science', 'conscience'] },
  { id: 'ente', vow: 'ɑ̃', ends: ['(ente|entes|ente)$'], words: ['attente', 'lente', 'tente', 'entente', 'pente', 'rente', 'vente', 'sente', 'mante', 'patente', 'fente', 'menthe', 'plante', 'chante', 'enchante', 'vante', 'tourmente', 'fréquente', 'présente', 'absente'] },
  { id: 'ême', ends: ['(ême|èmes|aime|aimes|ème|èmes)$'], words: ['même', 'aime', 'thème', 'poème', 'extrême', 'système', 'problème', 'crème', 'baptême', 'suprême', 'blasphème', 'carême', 'diadème', 'stratagème'] },
  { id: 'ame', ends: ['(âme|âmes|ame|ames|amme|ammes|emme|emmes)$'], words: ['âme', 'flamme', 'femme', 'dame', 'lame', 'rame', 'gamme', 'drame', 'programme', 'réclame', 'infâme', 'madame', 'calame', 'diagramme', 'télégramme'] },
  { id: 'arme', ends: ['(arme|armes|arm)$'], words: ['larme', 'arme', 'alarme', 'charme', 'gendarme', 'vacarme', 'désarme', 'carme', 'germe', 'ferme', 'terme', 'verme'] },
  { id: 'ique', ends: ['(ique|iques)$'], words: ['musique', 'magique', 'unique', 'tragique', 'logique', 'technique', 'publique', 'électrique', 'fantastique', 'classique', 'panique', 'comique', 'dynamique', 'rythmique', 'poétique', 'harmonique', 'plastique', 'critique', 'mécanique', 'politique', 'pratique', 'historique', 'pacifique', 'romantique', 'mystique', 'ironique', 'tactique', 'public', 'chic', 'trafic'] },
  { id: 'ène', ends: ['(ène|ènes|aine|aines|eine|eines|ène)$'], words: ['scène', 'chaîne', 'peine', 'haleine', 'plaine', 'semaine', 'fontaine', 'domaine', 'mène', 'reine', 'veine', 'laine', 'baleine', 'graine', 'certaine', 'lointaine', 'humaine', 'vaine', 'américaine', 'sereine', 'migraine', 'marraine'] },
  { id: 'ine', ends: ['(ine|ines|igne|ignes)$'], words: ['cuisine', 'routine', 'magazine', 'machine', 'usine', 'colline', 'ruine', 'vitrine', 'doctrine', 'sardine', 'copine', 'marine', 'mine', 'origine', 'divine', 'ligne', 'signe', 'digne', 'cygne', 'vigne', 'mandarine', 'cabine', 'piscine', 'vitamine'] },
  { id: 'ose', ends: ['(ose|oses|auze|ause|ôse)$'], words: ['rose', 'chose', 'pose', 'ose', 'prose', 'dose', 'glose', 'métamorphose', 'cause', 'pause', 'dose', 'exposé', 'close', 'morose', 'rose', 'virtuose', 'ecclose'] },
  { id: 'eux', ends: ['(eu|eux|œu|œux|eue|eues)$'], words: ['feu', 'jeu', 'peu', 'dieu', 'milieu', 'lieu', 'bleu', 'vœu', 'yeux', 'cieux', 'heureux', 'amoureux', 'précieux', 'merveilleux', 'silencieux', 'mystérieux', 'curieux', 'sérieux', 'joyeux', 'pieux', 'adieu', 'aveu', 'neveu', 'cheveu', 'enjeu', 'queue', 'bleue', 'deux', 'creux', 'nerveux'] },
  { id: 'ouille', ends: ['(ouille|ouilles)$'], words: ['grenouille', 'fouille', 'mouille', 'citrouille', 'nouille', 'rouille', 'bredouille', 'dépouille', 'brouille', 'quenouille', 'patrouille', 'embrouille', 'chatouille', 'gribouille'] },
  { id: 'ouche', ends: ['(ouche|ouches)$'], words: ['bouche', 'touche', 'mouche', 'couche', 'souche', 'farouche', 'louche', 'cartouche', 'escarmouche', 'effarouche', 'accouche', 'débouche', 'reprouche'] },
  { id: 'oche', ends: ['(oche|oches|osse|osses)$'], words: ['poche', 'roche', 'proche', 'cloche', 'accroche', 'brioche', 'reproche', 'approche', 'moche', 'gosse', 'fosse', 'bosse', 'carrosse', 'colosse', 'rosse', 'cosse'] },
  { id: 'iche', ends: ['(iche|iches)$'], words: ['riche', 'triche', 'niche', 'affiche', 'fiche', 'biche', 'friche', 'potiche', 'postiche', 'miche', 'pastiche', 'godiche', 'barbiche', 'chiche'] },
  { id: 'ache', ends: ['(ache|aches|âche|âches)$'], words: ['tâche', 'tache', 'cache', 'hache', 'vache', 'lâche', 'moustache', 'gouache', 'panache', 'attache', 'bravache', 'arrache', 'cravache', 'rache', 'fâche'] },
  { id: 'oute', ends: ['(oute|outes|outte|outtes|oûte|oûts?)$'], words: ['route', 'goutte', 'doute', 'écoute', 'joute', 'soute', 'déroute', 'voûte', 'croûte', 'toute', 'coûte', 'redoute', 'sans doute', 'banqueroute', 'dégoutte'] },
  { id: 'able', ends: ['(able|ables)$'], words: ['capable', 'incroyable', 'table', 'fable', 'cable', 'stable', 'aimable', 'formidable', 'inévitable', 'agréable', 'impeccable', 'adorable', 'durable', 'lamentable', 'sable', 'coupable', 'responsable'] },
  { id: 'iste', ends: ['(iste|istes)$'], words: ['piste', 'triste', 'artiste', 'liste', 'optimiste', 'dentiste', 'égoïste', 'pianiste', 'touriste', 'fataliste', 'pessimiste', 'chimiste', 'bassiste', 'styliste', 'journaliste', 'rappeuse'] },
  { id: 'ote', ends: ['(ote|otes|otte|ottes)$'], words: ['note', 'cote', 'vote', 'dévote', 'pilote', 'carotte', 'botte', 'marotte', 'culotte', 'flotte', 'grotte', 'ricotte', 'redingote', 'despote', 'idiote', 'échalote'] },
  { id: 'aque', ends: ['(aque|aques|ac|acs)$'], words: ['attaque', 'plaque', 'claque', 'baraque', 'flaque', 'cognac', 'sac', 'lac', 'tabac', 'vrac', 'bac', 'hamac', 'casaque', 'barraque', 'matraque'] },
  { id: 'ombre', ends: ['(ombre|ombres|ombrent)$'], words: ['ombre', 'sombre', 'nombre', 'décombre', 'encombre', 'pénombre', 'surnombre', 'décombres', 'dénombre'] },
];

/** Normalisation : minuscules, apostrophes courbes, sans espaces autour. */
function clean(word) { return word.toLowerCase().replace(/[’']/g, '’').replace(/\s+/g, ' ').trim(); }
const BY_WORD = new Map();
FAMILIES.forEach((f) => { f.regexes = f.ends.map((e) => new RegExp(e)); f.words.forEach((w) => { if (!BY_WORD.has(clean(w))) BY_WORD.set(clean(w), f); }); });

/** La famille d'un mot : d'abord la liste (sûr), ensuite les terminaisons (probable), sinon rien. */
function familyOf(word) {
  const w = clean(word);
  if (!w) return null;
  if (BY_WORD.has(w)) return BY_WORD.get(w);
  const last = w.split(' ').pop();
  return FAMILIES.find((f) => f.regexes.some((r) => r.test(last))) || null;
}
/** Le dictionnaire de rimes : les mots de la famille du mot cherché (sans lui-même), ou rien si on ne le connaît pas. */
function rhymesFor(word) { const f = familyOf(word); return f ? f.words.filter((w) => clean(w) !== clean(word)) : []; }
/** De quoi remplir les cases quand on joue en « débutant » : des débuts de phrase à compléter, pas des contraintes. */
const FILLERS = ['ce soir', 'mon flow', 'sur le beat', 'dans la rue', 'je rêve', 'tout le monde', 'un geste', 'mes mots', 'la ville', 'le temps', 'je danse', 'sans bruit', 'devant moi', 'je regarde', 'pas de limite', 'dans ma tête', 'sous la lune', 'je respire', 'sans peur', 'en rythme', 'toute la nuit', 'au micro', 'je te dis', 'dans mon sac', 'chaque jour', 'le matin', 'je cours', 'mon quartier', 'je compte', 'ma voix', 'la foule', 'je pense', 'un souvenir', 'je trace', 'sans doute', 'je sens', 'au fond', 'on avance', 'rien à perdre', 'je veux'];
/** Verdict : 'riche' (même famille), 'assonance' (même voyelle finale), ou null. */
function rhymeVerdict(target, typed) {
  const a = clean(target), b = clean(typed);
  if (!b || b === a || b.length < 2) return null;
  const fa = familyOf(a), fb = familyOf(b);
  if (!fa || !fb) return null;
  if (fa === fb) return 'riche';
  return (fa.vow || fa.id) === (fb.vow || fb.id) ? 'assonance' : null;
}
if (typeof module !== 'undefined') module.exports = { FAMILIES, FILLERS, familyOf, rhymeVerdict, clean, rhymesFor };
