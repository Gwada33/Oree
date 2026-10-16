# Préparation de l'étape 5 (LoRA) — licences, professeur en nuage, entraînement

Recherche du 11 octobre 2026, **sans code ni engagement de dépense**. Chaque affirmation est suivie de sa source ; ce que je n'ai pas pu vérifier est dit.

## 1. Licences des données (bloquant tant que ce n'est pas tranché)

| Jeu de données | Licence annoncée | Ce qui compte pour Orée |
|---|---|---|
| [Mind2Web](https://huggingface.co/datasets/osunlp/Mind2Web) | CC-BY-4.0 | La fiche dit « collecté et publié uniquement à des fins de recherche ». CC-BY autorise l'usage commercial avec attribution, mais cette phrase est une intention des auteurs : **à faire confirmer** avant usage dans un produit. |
| [Multimodal-Mind2Web](https://huggingface.co/datasets/osunlp/Multimodal-Mind2Web) | OpenRAIL | Licence différente de la précédente (restrictions d'usage). Non lue en détail. |
| [APIGen-MT-5k](https://huggingface.co/datasets/Salesforce/APIGen-MT-5k) | **CC-BY-NC-4.0 (usage non commercial)** | La fiche ajoute : « publié pour la recherche » et « généré en partie avec GPT-4 : ne pas l'utiliser pour développer des modèles concurrents d'OpenAI ». **À exclure** si Orée est un produit distribué. |
| [xlam-function-calling-60k](https://huggingface.co/datasets/Salesforce/xlam-function-calling-60k) | CC-BY-4.0 (métadonnée) | La fiche est protégée par une connexion : **je n'ai pas pu lire ses conditions complètes**. Le même éditeur ajoute des restrictions sur d'autres jeux ; à lire connecté avant tout usage. |
| [hermes-function-calling-v1](https://huggingface.co/datasets/NousResearch/hermes-function-calling-v1) | Apache 2.0 | La plus simple ; non étudiée plus loin. |

À noter : le dépôt tiers `UraionLabs/Uraion-Agent-Small`, écarté à l'étape 1, a été entraîné sur Hermes, APIGen-MT-5k et FineTome. Sa licence « Apache 2.0 » ne couvre donc pas
les restrictions de ses données d'entraînement : une raison de plus de ne pas l'utiliser.

**Question à trancher par toi : Orée est-il (ou sera-t-il) distribué commercialement ?** Sans cette réponse, je ne peux pas dire quels jeux sont utilisables.

## 2. Le professeur en nuage

- Qwen3.5-122B-A10B et Qwen3.5-397B-A17B sont sous Apache 2.0 ([122B](https://huggingface.co/Qwen/Qwen3.5-122B-A10B), [397B](https://huggingface.co/Qwen/Qwen3.5-397B-A17B)) : leurs sorties peuvent servir de données d'entraînement sans la restriction « concurrent d'OpenAI ».
- Tailles réelles des fichiers (API HuggingFace) : **122B en FP8 ≈ 127 Go**, **122B en Int4 ≈ 79 Go**, 35B-A3B en FP8 ≈ 38 Go ; le 397B en FP8 compte ≈ 403 milliards de paramètres, soit de l'ordre de 400 Go.
  Il faut donc au moins **2 GPU de 80 Go pour le 122B en FP8** (ou 1 seul, très juste, en Int4) et **plus de 5 GPU de 80 Go pour le 397B**. Ce sont des ordres de grandeur déduits des tailles de fichiers, avant mémoire de travail.
- Prix de location d'un H100 80 Go relevés dans la presse spécialisée : environ **1,4 à 2,5 $/h** selon le fournisseur ([RunPod 2,39 $, Lambda 2,49 $, Vast.ai 1,40–2,10 $](https://intuitionlabs.ai/articles/h100-rental-prices-cloud-comparison)). Donc **≈ 3 à 5 $/h pour un 122B sur 2 GPU**.
- **Non mesuré** : le débit réel (trajectoires par heure) et donc le coût total. Je n'invente pas de total. Méthode proposée : générer 50 trajectoires sur le 122B pour mesurer le temps et la part de trajectoires
  correctes, puis extrapoler avec la marge d'erreur. Le 35B-A3B (38 Go en FP8, un seul GPU) est le candidat « économique » à comparer.
- Les trajectoires doivent partir de **vraies cartes de page** produites par l'étape 2 : sans elles, le professeur voit autre chose que le modèle de poche.

## 3. L'entraînement

- Pas sur ce Mac (8 Go) : décision déjà prise dans `Docs/ia.md`.
- [Unsloth](https://unsloth.ai/docs/models/qwen3.5/fine-tune) prend en charge Qwen3.5 (dont le 2B), avec un notebook Colab officiel ; la fiche annonce **≈ 5 Go de VRAM pour un LoRA bf16 du 2B**.
  Elle **déconseille le QLoRA 4 bits** sur Qwen3.5 (écarts de quantification) et prévient que la compilation des noyaux Mamba est lente sur T4. Donc : LoRA bf16, GPU de 16 Go suffisant sur le papier. Non essayé ici.
- Fusion et retour en GGUF Q4_K_M : le LoRA fusionné doit être reconverti puis requantifié avec les outils de llama.cpp. **Non vérifié** pour l'architecture `qwen35` ; à tester sur un LoRA jouet avant de se fier au plan.
- L'évaluation (200 tâches, comparaison base / LoRA actuel / LoRA précédent) doit être écrite **avant** d'entraîner et ne contenir aucune tâche vue à l'entraînement. La mesure préliminaire
  (`Docs/ia-appel-outils.md`) donne la ligne de base de départ : 17 bons appels sur 26 avec grammaire, `done` et `ask_user` en échec.

## 4. Décisions qu'il me faut avant l'étape 5

1. Orée est-il distribué commercialement ? (détermine les jeux de données)
2. Budget de nuage acceptable pour le professeur (pour choisir 35B, 122B ou 397B).
3. Où héberger les traces de l'étape 4 : elles contiennent des pages visitées, donc potentiellement des données personnelles ; il faut une règle (jeux de test fabriqués uniquement, ou consentement).
