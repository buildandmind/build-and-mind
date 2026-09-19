<#
.SYNOPSIS
    Mesure la vitesse de generation (tokens/s) d'un modele charge dans LM Studio,
    via son API locale, sur un echauffement plus plusieurs passages, et calcule la
    mediane.

.DESCRIPTION
    Sert aux trois mesures de vitesse (conversation, dense dans la carte, dense en debordement) du
    protocole de la demonstration publique. Pour isoler l'effet du placement memoire,
    les deux mesures denses emploient le meme modele dense, le meme
    prompt et le meme budget; seule la configuration de chargement change.

    DEUX MODES DE COLLECTE, dans cet ordre :

    1. LM Studio compte lui-meme. Son API REST locale (endpoint natif
       /api/v0/chat/completions, "beta" chez l'editeur) renvoie un bloc "stats"
       avec tokens_per_second, time_to_first_token, generation_time et
       stop_reason. C'est la mesure retenue par defaut : elle vient du moteur
       qui genere, pas d'un chronometre exterieur.

    2. Repli diagnostic, en flux. Si le bloc "stats" n'arrive pas (version plus
       ancienne, ou endpoint /v1/ force par -ApiCompatible), le script refait
       le passage en streaming. Il conserve les tokens declares dans "usage"
       et compte separement les FRAGMENTS recus. Un fragment SSE n'est pas un
       token et un chronometre premier/dernier fragment omet le temps de
       generation du premier token : ce repli ne produit donc ni tokens/s ni
       mediane comparable. La serie sort en echec apres journalisation.

    PIEGE DES MODELES QUI RAISONNENT (gpt-oss-20b en est un). Ils peuvent
    emettre du raisonnement sur delta.reasoning ou delta.reasoning_content.
    Dans le repli SSE, ces emissions restent des fragments : elles vont dans
    FragmentsRaisonnement. TokensRaisonnement n'est rempli que par le compteur
    officiel usage.completion_tokens_details.reasoning_tokens.

    Comparaison causale : les deux mesures denses utilisent le meme
    fichier dense, le meme prompt, le meme contexte, le meme plafond de tokens
    et la meme session. Seul le placement CPU/GPU declare change.

.PARAMETER Etiquette
    Nom court de la condition, par exemple "chat-moe", "dense-gpu" ou
    "dense-offload". Sert de nom de fichier pour les journaux. Ne jamais
    reutiliser une etiquette pour une autre condition ou un autre modele.

.PARAMETER Modele
    Identifiant du modele a interroger. Par defaut, le script demande a
    LM Studio quel modele est CHARGE et refuse de deviner s'il n'arrive pas a
    trancher. A renseigner uniquement si plusieurs modeles sont charges en
    meme temps.

.PARAMETER ConfigurationChargement
    Texte obligatoire qui decrit la configuration reellement visible dans LM
    Studio : contexte charge, GPU offload, expert offload, Flash Attention et,
    pour la mesure en debordement, nombre exact de couches sur GPU/CPU. L'API ne publie
    pas toujours tous ces reglages; les rendre obligatoires evite un CSV
    impossible a reproduire.

.PARAMETER PromptFile
    Chemin du fichier texte contenant le prompt fixe. Par defaut
    ..\examples\prompt-vitesse.txt : le prompt anglais de la demonstration,
    sur les poids, le contexte et le partage CPU/GPU (trois paragraphes,
    160 a 180 mots). Utiliser exactement le meme prompt et les memes reglages
    de generation pour les deux configurations de chargement.

.PARAMETER Passages
    Nombre de passages MESURES. Le protocole public en
    demande 3 ; ne pas descendre en dessous. Un passage d'echauffement
    supplementaire est toujours fait avant, et jamais compte.

.PARAMETER MaxTokens
    Plafond de tokens generes par passage, identique pour la paire dense :
    il fixe la meme limite pour les deux conditions. Le modele peut terminer
    avant ce plafond : comparer les tokens effectivement generes et le debit
    annonce par le moteur, pas seulement la duree totale.
    Duree a prevoir : environ MaxTokens / vitesse attendue, par passage,
    echauffement compris. A 500 tokens : environ 6 s par passage a 90 tokens/s
    (modele retenu), environ 85 s par passage a 6 tokens/s (modele en
    debordement, soit environ 6 minutes pour la serie complete).

.PARAMETER EffortRaisonnement
    Optionnel, "low" / "medium" / "high". Envoie le champ reasoning_effort
    accepte par gpt-oss. Non envoye par defaut : un champ inconnu ferait
    refuser la requete par certaines versions. A n'utiliser que si le
    raisonnement mange tout le budget de tokens (visible dans la colonne
    TokensRaisonnement).

.PARAMETER Systeme
    Optionnel. Message systeme ajoute avant le prompt. Laisser vide pour la
    mesure de reference : les deux conditions denses doivent recevoir exactement
    la meme chose.

.PARAMETER BaseUrl
    Racine du serveur local de LM Studio. Le serveur doit etre demarre avant de
    lancer ce script : dans LM Studio, onglet "Developer", bouton
    "Start Server" (port 1234 par defaut).

.PARAMETER ApiCompatible
    Force l'endpoint compatible OpenAI (/v1/chat/completions) pour l'inference.
    L'inventaire natif /api/v0/models reste obligatoire pour confirmer que le
    LLM est charge et journaliser son contexte.

.EXAMPLE
    # Avec le modele retenu (gpt-oss-20b) charge dans LM Studio :
    .\mesurer-vitesse.ps1 -Etiquette "chat-moe" -ConfigurationChargement "contexte=8192; GPU offload=full; expert offload=off; Flash Attention=on"

    # Meme Qwen3-14B dense, avec ses deux placements mesures separement :
    .\mesurer-vitesse.ps1 -Etiquette "dense-gpu" -Modele "<ID>" -ConfigurationChargement "contexte=8192; couches GPU=toutes; couches CPU=0; Flash Attention=on"
    .\mesurer-vitesse.ps1 -Etiquette "dense-offload" -Modele "<meme-ID>" -ConfigurationChargement "contexte=8192; couches GPU=<N>; couches CPU=<M>; Flash Attention=on"

.NOTES
    Verifier ces points avec la version de LM Studio installee avant utilisation :
    - que /api/v0/models et /api/v0/chat/completions existent sur la version
      installee, et que le bloc "stats" contient bien tokens_per_second (sinon
      le script produit seulement un diagnostic SSE et invalide la serie) ;
    - le nom exact du modele charge, tel que le script l'affiche au demarrage :
      c'est CE nom qui va dans le journal ;
    - les temps reels, tres differents d'une machine a l'autre.
    Fichier volontairement en ASCII pur (pas d'accent, pas de tiret cadratin) :
    PowerShell 5.1 lit un fichier sans BOM avec l'encodage ANSI de Windows et
    abimerait les caracteres accentues.
    Voir ../README.fr.md, section "Observer le modele et le reseau".
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Etiquette,

    [string]$Modele = "",

    [string]$PromptFile = "$PSScriptRoot\..\examples\prompt-vitesse.txt",

    [ValidateRange(3, 10)]
    [int]$Passages = 3,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigurationChargement,

    [ValidateRange(1, 1000000)]
    [int]$MaxTokens = 500,

    [ValidateSet("", "low", "medium", "high")]
    [string]$EffortRaisonnement = "",

    [string]$Systeme = "",

    [string]$BaseUrl = "http://127.0.0.1:1234",

    [switch]$ApiCompatible,

    [ValidateRange(1, 1440)]
    [int]$TimeoutMinutes = 30,

    [string]$SortieDir = "$PSScriptRoot\..\mesures"
)

$ErrorActionPreference = "Stop"

# --- 0. Preparation ---------------------------------------------------------

if (-not (Test-Path $PromptFile)) {
    throw "Fichier de prompt introuvable : $PromptFile"
}
$promptPath = (Resolve-Path -LiteralPath $PromptFile -ErrorAction Stop).Path
$prompt = (Get-Content -LiteralPath $promptPath -Raw).Trim()
if (-not $prompt) { throw "Le fichier de prompt est vide : $promptPath" }
$promptSha256 = (Get-FileHash -LiteralPath $promptPath -Algorithm SHA256).Hash.ToLowerInvariant()

function Get-Sha256Texte {
    param([string]$Texte)
    if (-not $Texte) { return "" }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $octets = [Text.Encoding]::UTF8.GetBytes($Texte)
        return (-join ($sha.ComputeHash($octets) | ForEach-Object { $_.ToString("x2") }))
    }
    finally { $sha.Dispose() }
}
$systemeSha256 = Get-Sha256Texte -Texte $Systeme

New-Item -ItemType Directory -Path $SortieDir -Force | Out-Null
$etiquetteFichier = ($Etiquette -replace "[^A-Za-z0-9._-]", "-").Trim("-")
if (-not $etiquetteFichier) { throw "Etiquette inutilisable comme nom de fichier." }
$horodatage = Get-Date -Format "yyyyMMdd-HHmmss"
$journalCsv = Join-Path $SortieDir "vitesse-$etiquetteFichier-$horodatage.csv"
$journalBrut = Join-Path $SortieDir "vitesse-$etiquetteFichier-$horodatage-brut.jsonl"

$BaseUrl = $BaseUrl.TrimEnd("/")
$urlNatif = "$BaseUrl/api/v0/chat/completions"
$urlCompatible = "$BaseUrl/v1/chat/completions"

Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

# Ne jamais ecrire a l'ecran un nom de modele suppose : on demande a LM Studio
# quel modele il sert reellement, et c'est CE nom qui va dans le journal.
#
# Attention : /v1/models liste TOUS les modeles telecharges, charges ou non.
# Prendre le premier de la liste donnerait un nom faux une fois sur deux.
# L'endpoint natif /api/v0/models, lui, porte un champ "state" (loaded /
# not-loaded) : c'est celui qu'on interroge en premier.
function Get-ModeleCharge {
    try {
        $reponse = Invoke-RestMethod -Uri "$BaseUrl/api/v0/models" -Method Get -TimeoutSec 15
    }
    catch {
        throw "Impossible de verifier l'etat charge via /api/v0/models : $($_.Exception.Message)"
    }

    $charges = @($reponse.data | Where-Object {
        "$($_.state)" -eq "loaded" -and "$($_.type)" -eq "llm"
    })
    if ($Modele) {
        $selection = @($charges | Where-Object { "$($_.id)" -eq $Modele })
        if ($selection.Count -ne 1) {
            $noms = @($charges | ForEach-Object { $_.id }) -join ", "
            throw "Le modele impose '$Modele' n'est pas un unique LLM charge. LLM charges : $noms"
        }
    }
    else {
        $selection = $charges
        if ($selection.Count -ne 1) {
            $noms = @($charges | ForEach-Object { $_.id }) -join ", "
            throw "Un seul LLM charge est requis sans -Modele; $($selection.Count) trouve(s) : $noms"
        }
    }

    $m = $selection[0]
    Write-Host ("LLM charge confirme par LM Studio : {0}" -f $m.id)
    foreach ($champ in @("type", "arch", "quantization", "max_context_length", "loaded_context_length", "runtime")) {
        if ($m.PSObject.Properties.Name -contains $champ) {
            Write-Host ("  {0,-22}: {1}" -f $champ, $m.$champ)
        }
    }
    return $m
}

try {
    $modeleMeta = Get-ModeleCharge
    $modeleCharge = $modeleMeta.id
}
catch {
    throw "$($_.Exception.Message)`nLe serveur local est-il demarre et le modele voulu reellement charge ? Base testee : $BaseUrl"
}
$typeModele = "$($modeleMeta.type)"
$architecture = "$($modeleMeta.arch)"
$quantification = "$($modeleMeta.quantization)"
$contexteCharge = "$($modeleMeta.loaded_context_length)"
$contexteMax = "$($modeleMeta.max_context_length)"
$runtime = "$($modeleMeta.runtime)"

function New-CorpsRequete {
    param([bool]$EnFlux)
    $messages = @()
    if ($Systeme) { $messages += @{ role = "system"; content = $Systeme } }
    $messages += @{ role = "user"; content = $prompt }

    $corps = [ordered]@{
        model       = $modeleCharge
        messages    = $messages
        max_tokens  = $MaxTokens
        temperature = 0
        stream      = $EnFlux
    }
    if ($EffortRaisonnement) { $corps["reasoning_effort"] = $EffortRaisonnement }
    if ($EnFlux) { $corps["stream_options"] = @{ include_usage = $true } }
    return ($corps | ConvertTo-Json -Depth 6)
}

function New-Client {
    $c = [System.Net.Http.HttpClient]::new()
    # Sans cette ligne, HttpClient abandonne au bout de 100 secondes : le modele
    # en debordement (quelques tokens/s) depasse ce delai et la mesure echouerait
    # exactement sur le passage qui compte le plus.
    $c.Timeout = [TimeSpan]::FromMinutes($TimeoutMinutes)
    return $c
}

function Invoke-Http {
    param([System.Net.Http.HttpClient]$Client, [string]$Url, [string]$Corps, [bool]$Flux)
    $requete = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Url)
    $requete.Content = [System.Net.Http.StringContent]::new($Corps, [System.Text.Encoding]::UTF8, "application/json")
    $option = if ($Flux) {
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    } else {
        [System.Net.Http.HttpCompletionOption]::ResponseContentRead
    }
    $reponse = $Client.SendAsync($requete, $option).GetAwaiter().GetResult()
    if (-not $reponse.IsSuccessStatusCode) {
        $texte = ""
        try { $texte = $reponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
        throw ("{0} a repondu {1} {2}. Corps : {3}" -f $Url, [int]$reponse.StatusCode, $reponse.ReasonPhrase, $texte)
    }
    return $reponse
}

# --- 1a. Passage compte par LM Studio (methode preferee) ---------------------

function Get-NombreFiniRequis {
    param(
        [object]$Objet,
        [string]$Champ,
        [double]$Minimum,
        [bool]$MinimumInclusif
    )
    if (-not $Objet -or -not ($Objet.PSObject.Properties.Name -contains $Champ)) {
        throw "Reponse stats invalide : champ '$Champ' absent."
    }
    $brut = $Objet.$Champ
    if ($null -eq $brut -or $brut -is [string] -or $brut -is [bool]) {
        throw "Reponse stats invalide : '$Champ' n'est pas un nombre JSON."
    }
    try { $nombre = [double]$brut }
    catch { throw "Reponse stats invalide : '$Champ' n'est pas numerique." }
    if ([double]::IsNaN($nombre) -or [double]::IsInfinity($nombre)) {
        throw "Reponse stats invalide : '$Champ' n'est pas fini."
    }
    if (($MinimumInclusif -and $nombre -lt $Minimum) -or
        (-not $MinimumInclusif -and $nombre -le $Minimum)) {
        $operateur = if ($MinimumInclusif) { ">=" } else { ">" }
        throw "Reponse stats invalide : '$Champ' doit etre $operateur $Minimum."
    }
    return $nombre
}

function Get-EntierRequis {
    param(
        [object]$Objet,
        [string]$Champ,
        [long]$Minimum,
        [long]$Maximum = [long]::MaxValue
    )
    $nombre = Get-NombreFiniRequis -Objet $Objet -Champ $Champ -Minimum $Minimum -MinimumInclusif $true
    if ($nombre -ne [math]::Truncate($nombre) -or $nombre -gt $Maximum) {
        throw "Reponse stats invalide : '$Champ' doit etre un entier entre $Minimum et $Maximum."
    }
    return [long]$nombre
}

function Invoke-PassageStats {
    $client = New-Client
    try {
        $corps = New-CorpsRequete -EnFlux $false
        $tEnvoi = Get-Date
        $reponse = Invoke-Http -Client $client -Url $urlNatif -Corps $corps -Flux $false
        $texte = $reponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    finally {
        $client.Dispose()
    }

    $texte | Add-Content -Path $journalBrut -Encoding UTF8
    $objet = $texte | ConvertFrom-Json
    if (-not ($objet.PSObject.Properties.Name -contains "stats") -or
        -not $objet.stats -or
        -not ($objet.stats.PSObject.Properties.Name -contains "tokens_per_second")) {
        return $null   # cette version ne compte pas pour nous : diagnostic SSE
    }

    # Un champ tokens_per_second isole ne suffit pas a rendre un passage
    # comparable. On exige une reponse native complete et coherente avant de
    # reprendre le compteur du serveur.
    if (($objet.PSObject.Properties.Name -contains "error") -and $null -ne $objet.error) {
        throw "Reponse stats invalide : le serveur renvoie aussi un objet error."
    }
    if ("$($objet.object)" -ne "chat.completion") {
        throw "Reponse stats invalide : object='$($objet.object)' au lieu de 'chat.completion'."
    }
    if (-not $objet.model -or "$($objet.model)" -ne "$modeleCharge") {
        throw "Reponse stats invalide : modele repondu '$($objet.model)', modele charge '$modeleCharge'."
    }
    $choix = @($objet.choices)
    if ($choix.Count -ne 1 -or -not $choix[0].message) {
        throw "Reponse stats invalide : un unique choix avec message assistant est requis."
    }
    if ("$($choix[0].message.role)" -ne "assistant") {
        throw "Reponse stats invalide : le message final n'a pas le role assistant."
    }
    $aContenu = -not [string]::IsNullOrWhiteSpace("$($choix[0].message.content)")
    $aRaisonnement = -not [string]::IsNullOrWhiteSpace("$($choix[0].message.reasoning)") -or
        -not [string]::IsNullOrWhiteSpace("$($choix[0].message.reasoning_content)")
    if (-not $aContenu -and -not $aRaisonnement) {
        throw "Reponse stats invalide : aucun contenu ni raisonnement assistant."
    }

    $raisonChoix = "$($choix[0].finish_reason)"
    $raisonStats = "$($objet.stats.stop_reason)"
    $arretsCompatibles = @{
        stop   = @("eosFound", "stopStringFound")
        length = @("maxPredictedTokensReached", "contextLengthReached")
    }
    if (-not $arretsCompatibles.ContainsKey($raisonChoix) -or
        $arretsCompatibles[$raisonChoix] -notcontains $raisonStats) {
        throw "Reponse stats invalide : fins incompatibles (finish_reason='$raisonChoix', stop_reason='$raisonStats')."
    }

    $vitesse = Get-NombreFiniRequis -Objet $objet.stats -Champ "tokens_per_second" -Minimum 0 -MinimumInclusif $false
    $ttft = Get-NombreFiniRequis -Objet $objet.stats -Champ "time_to_first_token" -Minimum 0 -MinimumInclusif $true
    $dureeGeneration = Get-NombreFiniRequis -Objet $objet.stats -Champ "generation_time" -Minimum 0 -MinimumInclusif $false
    if (-not $objet.usage) { throw "Reponse stats invalide : bloc usage absent." }
    $tokensPrompt = Get-EntierRequis -Objet $objet.usage -Champ "prompt_tokens" -Minimum 1
    $tokensGeneres = Get-EntierRequis -Objet $objet.usage -Champ "completion_tokens" -Minimum 1 -Maximum $MaxTokens
    if ($objet.usage.PSObject.Properties.Name -contains "total_tokens") {
        $tokensTotal = Get-EntierRequis -Objet $objet.usage -Champ "total_tokens" -Minimum 2
        if ($tokensTotal -ne ($tokensPrompt + $tokensGeneres)) {
            throw "Reponse stats invalide : total_tokens ne vaut pas prompt_tokens + completion_tokens."
        }
    }

    $tokensRaisonnement = $null
    if ($objet.usage -and ($objet.usage.PSObject.Properties.Name -contains "completion_tokens_details")) {
        if ($objet.usage.completion_tokens_details -and
            ($objet.usage.completion_tokens_details.PSObject.Properties.Name -contains "reasoning_tokens")) {
            $tokensRaisonnement = Get-EntierRequis -Objet $objet.usage.completion_tokens_details `
                -Champ "reasoning_tokens" -Minimum 0 -Maximum $tokensGeneres
        }
    }

    return [PSCustomObject]@{
        Methode            = "stats LM Studio"
        MesureComparable   = $true
        EndpointInference  = $urlNatif
        DateHeure          = $tEnvoi.ToString("s")
        DelaiPremierTokenS = [math]::Round($ttft, 3)
        DureeGenerationS   = [math]::Round($dureeGeneration, 3)
        DelaiPremierFragmentS = $null
        DureeFluxObserveeS = $null
        TokensPrompt       = $tokensPrompt
        TokensGeneres      = $tokensGeneres
        TokensRaisonnement = $tokensRaisonnement
        FragmentsContenu   = $null
        FragmentsRaisonnement = $null
        RaisonArret        = $raisonStats
        FinFlux             = "reponse HTTP complete"
        TokensParSeconde   = [math]::Round($vitesse, 2)
    }
}

# --- 1b. Passage chronometre cote client (repli) -----------------------------

function Invoke-PassageFlux {
    $url = if ($ApiCompatible) { $urlCompatible } else { $urlNatif }
    $client = New-Client
    $lecteur = $null
    try {
        $corps = New-CorpsRequete -EnFlux $true
        $tEnvoi = Get-Date
        # Ne jamais retenter en supprimant silencieusement le message systeme,
        # reasoning_effort ou stream_options : les conditions ne seraient plus
        # comparables. Une requete refusee invalide la serie.
        $reponse = Invoke-Http -Client $client -Url $url -Corps $corps -Flux $true

        $flux = $reponse.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $lecteur = [System.IO.StreamReader]::new($flux)

        $tPremierFragment = $null
        $tDernierFragment = $null
        $morceauxContenu = 0
        $morceauxRaisonnement = 0
        $tokensUsage = $null
        $tokensPrompt = $null
        $tokensRaisonnement = $null
        $aVuDone = $false
        $raisonArret = ""

        while ($null -ne ($ligne = $lecteur.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($ligne)) { continue }
            if (-not $ligne.StartsWith("data:")) { continue }
            $donnee = $ligne.Substring(5).Trim()
            $donnee | Add-Content -Path $journalBrut -Encoding UTF8
            if ($donnee -eq "[DONE]") {
                $aVuDone = $true
                break
            }

            $objet = $donnee | ConvertFrom-Json
            $delta = $null
            if ($objet.choices -and $objet.choices.Count -gt 0) {
                $delta = $objet.choices[0].delta
                if ($objet.choices[0].PSObject.Properties.Name -contains "finish_reason" -and
                    $objet.choices[0].finish_reason) {
                    $raisonArret = "$($objet.choices[0].finish_reason)"
                }
            }

            if ($delta) {
                # Un modele qui raisonne emet d'abord sur reasoning /
                # reasoning_content. Ce sont des fragments de transport, gardes
                # a part sans les presenter comme des tokens.
                $aDuContenu = [bool]$delta.content
                $aDuRaisonnement = [bool]($delta.reasoning) -or [bool]($delta.reasoning_content)
                if ($aDuContenu -or $aDuRaisonnement) {
                    if (-not $tPremierFragment) { $tPremierFragment = Get-Date }
                    $tDernierFragment = Get-Date
                    if ($aDuContenu) { $morceauxContenu++ }
                    if ($aDuRaisonnement) { $morceauxRaisonnement++ }
                }
            }
            if ($objet.PSObject.Properties.Name -contains "usage" -and $objet.usage) {
                $tokensUsage = $objet.usage.completion_tokens
                $tokensPrompt = $objet.usage.prompt_tokens
                if ($objet.usage.PSObject.Properties.Name -contains "completion_tokens_details") {
                    $tokensRaisonnement = $objet.usage.completion_tokens_details.reasoning_tokens
                }
            }
        }
    }
    finally {
        if ($lecteur) { $lecteur.Close() }
        $client.Dispose()
    }

    if (-not $aVuDone -and -not $raisonArret) {
        throw "Flux SSE termine sans marqueur [DONE] ni finish_reason; passage incomplet."
    }
    if (-not $tPremierFragment) {
        throw "Aucun contenu recu. Verifier qu'un modele est bien charge dans LM Studio et que le prompt n'est pas vide."
    }

    $dureeFluxObservee = ($tDernierFragment - $tPremierFragment).TotalSeconds
    if ($dureeFluxObservee -lt 0) { $dureeFluxObservee = 0 }
    $finFlux = if ($aVuDone) { "[DONE]" } else { "finish_reason=$raisonArret" }

    return [PSCustomObject]@{
        Methode            = "flux SSE (diagnostic; stats absentes)"
        MesureComparable   = $false
        EndpointInference  = $url
        DateHeure          = $tEnvoi.ToString("s")
        DelaiPremierTokenS = $null
        DureeGenerationS   = $null
        DelaiPremierFragmentS = [math]::Round(($tPremierFragment - $tEnvoi).TotalSeconds, 3)
        DureeFluxObserveeS = [math]::Round($dureeFluxObservee, 3)
        TokensPrompt       = $tokensPrompt
        TokensGeneres      = $tokensUsage
        TokensRaisonnement = $tokensRaisonnement
        FragmentsContenu   = $morceauxContenu
        FragmentsRaisonnement = $morceauxRaisonnement
        RaisonArret        = $raisonArret
        FinFlux             = $finFlux
        TokensParSeconde   = $null
    }
}

function Invoke-Passage {
    param([string]$Nom)
    if (-not $ApiCompatible) {
        $r = Invoke-PassageStats
        if ($r) { return $r }
    }
    return Invoke-PassageFlux
}

# --- 2. Echauffement puis passages mesures ----------------------------------

Write-Host ""
Write-Host "Echauffement (non compte) - $Etiquette"
$echauffement = Invoke-Passage -Nom "echauffement"
if ($echauffement.MesureComparable) {
    Write-Host ("  {0} tokens/s ({1})" -f $echauffement.TokensParSeconde, $echauffement.Methode)
}
else {
    Write-Warning "Echauffement SSE diagnostique sans statistique native : aucun tokens/s comparable."
}

$resultats = @()
for ($i = 1; $i -le $Passages; $i++) {
    Write-Host "--- Passage $i / $Passages ($Etiquette) ---"
    $r = Invoke-Passage -Nom "passage-$i"
    $r | Add-Member -NotePropertyName Passage -NotePropertyValue $i
    $r | Add-Member -NotePropertyName Modele -NotePropertyValue $modeleCharge
    $r | Add-Member -NotePropertyName Etiquette -NotePropertyValue $Etiquette
    $r | Add-Member -NotePropertyName TypeModele -NotePropertyValue $typeModele
    $r | Add-Member -NotePropertyName Architecture -NotePropertyValue $architecture
    $r | Add-Member -NotePropertyName Quantification -NotePropertyValue $quantification
    $r | Add-Member -NotePropertyName ContexteCharge -NotePropertyValue $contexteCharge
    $r | Add-Member -NotePropertyName ContexteMax -NotePropertyValue $contexteMax
    $r | Add-Member -NotePropertyName Runtime -NotePropertyValue $runtime
    $r | Add-Member -NotePropertyName ConfigurationChargement -NotePropertyValue $ConfigurationChargement
    $r | Add-Member -NotePropertyName PromptFile -NotePropertyValue $promptPath
    $r | Add-Member -NotePropertyName PromptSha256 -NotePropertyValue $promptSha256
    $r | Add-Member -NotePropertyName MaxTokens -NotePropertyValue $MaxTokens
    $r | Add-Member -NotePropertyName Temperature -NotePropertyValue 0
    $r | Add-Member -NotePropertyName SystemePresent -NotePropertyValue ([bool]$Systeme)
    $r | Add-Member -NotePropertyName SystemeSha256 -NotePropertyValue $systemeSha256
    $r | Add-Member -NotePropertyName EffortRaisonnement -NotePropertyValue $EffortRaisonnement
    $resultats += $r
    if ($r.MesureComparable) {
        Write-Host ("  {0} tokens en {1} s -> {2} tokens/s [{3}]" -f `
            $r.TokensGeneres, $r.DureeGenerationS, $r.TokensParSeconde, $r.Methode)
    }
    else {
        Write-Warning ("  diagnostic SSE : {0} fragment(s) contenu, {1} raisonnement; aucun tokens/s" -f `
            $r.FragmentsContenu, $r.FragmentsRaisonnement)
    }
    if ($r.TokensRaisonnement) {
        Write-Host ("  dont {0} token(s) de raisonnement" -f $r.TokensRaisonnement)
    }
    if ($i -lt $Passages) {
        Write-Host "  Pause de 3 s avant le passage suivant (laisser la carte se stabiliser)..."
        Start-Sleep -Seconds 3
    }
}

# --- 3. Stabilite, mediane et journal ----------------------------------------

# Verifie la provenance AVANT d'ecrire un CSV exploitable.
$modeleApres = Get-ModeleCharge
foreach ($champStable in @("id", "type", "arch", "quantization", "loaded_context_length", "max_context_length", "runtime")) {
    if ("$($modeleApres.$champStable)" -ne "$($modeleMeta.$champStable)") {
        throw "Le modele charge ou son contexte a change pendant la serie ($champStable : debut '$($modeleMeta.$champStable)', fin '$($modeleApres.$champStable)'). Journal invalide."
    }
}
$promptSha256Apres = (Get-FileHash -LiteralPath $promptPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($promptSha256Apres -ne $promptSha256) {
    throw "Le fichier de prompt a change pendant la serie. Aucun CSV n'a ete ecrit."
}

$comparables = @($resultats | Where-Object { $_.MesureComparable -and $null -ne $_.TokensParSeconde })
$mediane = $null
$ecart = $null
if ($comparables.Count -eq $resultats.Count) {
    $valeursTri = @($comparables.TokensParSeconde | Sort-Object)
    $n = $valeursTri.Count
    if ($n % 2 -eq 1) {
        $mediane = $valeursTri[[int](($n - 1) / 2)]
    }
    else {
        $mediane = ($valeursTri[[int]($n / 2) - 1] + $valeursTri[[int]($n / 2)]) / 2
    }
    $ecart = [math]::Round($valeursTri[$n - 1] - $valeursTri[0], 2)
}

$resultats |
    Select-Object Etiquette, Passage, Modele, TypeModele, Architecture, Quantification,
                  ContexteCharge, ContexteMax, Runtime, ConfigurationChargement,
                  PromptFile, PromptSha256, MaxTokens, Temperature, SystemePresent,
                  SystemeSha256, EffortRaisonnement, EndpointInference, Methode,
                  MesureComparable, DateHeure, DelaiPremierTokenS, DureeGenerationS,
                  DelaiPremierFragmentS, DureeFluxObserveeS, TokensPrompt,
                  TokensGeneres, TokensRaisonnement, FragmentsContenu,
                  FragmentsRaisonnement, RaisonArret, FinFlux, TokensParSeconde |
    Export-Csv -LiteralPath $journalCsv -NoTypeInformation -Encoding UTF8

if ($comparables.Count -ne $resultats.Count) {
    Write-Host ("Journal diagnostic : {0}" -f $journalCsv)
    Write-Host ("Reponses brutes    : {0}" -f $journalBrut)
    throw "Statistiques natives absentes sur au moins un passage : aucun tokens/s ni mediane comparable. Serie invalide."
}

$methodes = @($resultats.Methode | Sort-Object -Unique) -join " + "

Write-Host ""
Write-Host "=== Resume ($Etiquette) ==="
Write-Host ("Modele            : {0}" -f $modeleCharge)
Write-Host ("Configuration     : {0}" -f $ConfigurationChargement)
Write-Host ("Contexte charge   : {0} tokens" -f $contexteCharge)
Write-Host ("Methode de comptage: {0}" -f $methodes)
Write-Host ("Plafond de tokens : {0} (identique pour les deux conditions denses)" -f $MaxTokens)
Write-Host ("Passages (tok/s)  : {0}" -f (($resultats.TokensParSeconde) -join ", "))
Write-Host ("Mediane           : {0} tokens/s" -f $mediane)
Write-Host ("Ecart max-min     : {0} tokens/s" -f $ecart)
Write-Host ("Journal CSV       : {0}" -f $journalCsv)
Write-Host ("Reponses brutes   : {0}" -f $journalBrut)
Write-Host ""
Write-Host "A noter avec vos resultats : les $Passages valeurs, la mediane, l'ecart,"
Write-Host "la configuration de chargement, les empreintes de provenance, la methode, la date et la version de LM Studio"
Write-Host "(fenetre 'About', menu de l'application)."
