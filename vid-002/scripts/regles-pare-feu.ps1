<#
.SYNOPSIS
    Inventorie, pose ou retire les regles sortantes de VID-002 et gere, avec
    restauration exacte, le journal du Pare-feu Windows Defender.

.DESCRIPTION
    Une regle -Program ne protege que le chemin exact qu'elle vise. Le script
    localise donc le dossier d'installation confirme de LM Studio et
    d'AnythingLLM, puis enumere tous ses .exe, y compris les helpers et
    updaters qui ne tournent pas encore. Il refuse de poser un lot si l'une des
    deux applications n'a aucun dossier confirme.

    Les noms de regle incorporent un hash du chemin. Une relance verifie le
    filtre Program et les proprietes de chaque regle; les regles perimees sont
    remplacees ou retirees.

    -ActiverJournal sauvegarde d'abord, dans le magasin local PersistentStore,
    LogAllowed, LogBlocked, LogFileName et LogMaxSizeKilobytes, et conserve
    separement l'ActiveStore effectif. Il ecrit dans le magasin local puis
    verifie l'effet reel : une GPO qui empeche les valeurs attendues fait
    echouer l'activation et declenche la restauration locale.
    -DesactiverJournal restaure le PersistentStore et confirme aussi l'etat
    effectif. Le fichier d'etat reste dans mesures/, dossier prive et ignore
    par Git, jusqu'a ce que les deux verifications reussissent.

    IMPORTANT : bloquer un programme coupe tout son trafic sortant, y compris
    une recherche web volontaire. Poser les regles apres vos essais de recherche web.

.PARAMETER CheminLMStudio
    Chemin confirme de l'executable principal. Le dossier qui le contient est
    enumere recursivement. A utiliser si la decouverte automatique echoue.

.PARAMETER CheminAnythingLLM
    Meme chose pour AnythingLLM Desktop.

.PARAMETER Lister
    Inventorie les executables et les regles existantes sans rien modifier.

.PARAMETER Retirer
    Retire toutes les regles dont le nom commence par BuildAndMind-Bloquer-.

.PARAMETER ActiverJournal
    Sauvegarde l'etat des trois profils, puis active les connexions autorisees
    et bloquees avec une taille maximale de 32767 Ko.

.PARAMETER DesactiverJournal
    Restaure exactement l'etat local sauvegarde par -ActiverJournal et verifie
    que l'etat effectif retrouve lui aussi l'etat observe avant activation.

.PARAMETER EtatJournal
    Fichier JSON prive qui conserve l'etat anterieur des trois profils. Il doit
    rester dans mesures/ ou une autre zone ignoree par Git.

.PARAMETER CheminJournalActif
    Chemin commun configure sur les trois profils pendant la session.

.EXAMPLE
    .\regles-pare-feu.ps1 -ActiverJournal
    .\regles-pare-feu.ps1 -Lister
    .\regles-pare-feu.ps1
    .\regles-pare-feu.ps1 -Retirer
    .\regles-pare-feu.ps1 -DesactiverJournal

.NOTES
    Verifier la compatibilite avec la version de PowerShell installee avant
    utilisation. Fichier volontairement en ASCII pur pour PowerShell 5.1.
#>

[CmdletBinding()]
param(
    [string]$CheminLMStudio = "",
    [string]$CheminAnythingLLM = "",
    [switch]$Lister,
    [switch]$Retirer,
    [switch]$ActiverJournal,
    [switch]$DesactiverJournal,
    [string]$EtatJournal = "$PSScriptRoot\..\mesures\parefeu-etat-profils.json",
    [string]$CheminJournalActif = "$env:SystemRoot\system32\LogFiles\Firewall\pfirewall.log"
)

$ErrorActionPreference = "Stop"
$PrefixeRegle = "BuildAndMind-Bloquer-"

$nombreModes = 0
foreach ($mode in @($Lister, $Retirer, $ActiverJournal, $DesactiverJournal)) {
    if ($mode) { $nombreModes++ }
}
if ($nombreModes -gt 1) {
    throw "Choisir un seul mode : -Lister, -Retirer, -ActiverJournal ou -DesactiverJournal."
}

function Test-Administrateur {
    $identite = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identite)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not $Lister -and -not (Test-Administrateur)) {
    throw "Ce mode modifie le pare-feu : relancer PowerShell en tant qu'administrateur."
}

function Get-EtatProfils {
    param(
        [ValidateSet("PersistentStore", "ActiveStore")]
        [string]$PolicyStore
    )
    $profils = @(Get-NetFirewallProfile -PolicyStore $PolicyStore -ErrorAction Stop |
        Select-Object Name, LogAllowed, LogBlocked, LogFileName, LogMaxSizeKilobytes)
    $noms = @($profils | ForEach-Object { "$($_.Name)" } | Sort-Object)
    if (($noms -join ",") -ne "Domain,Private,Public") {
        throw "Profils inattendus dans $PolicyStore : $($noms -join ', '). Domain, Private et Public sont requis."
    }
    return $profils
}

function Set-EtatProfils {
    param([object[]]$Etats)
    foreach ($etat in $Etats) {
        Set-NetFirewallProfile -PolicyStore PersistentStore -Name $etat.Name `
            -LogAllowed $etat.LogAllowed `
            -LogBlocked $etat.LogBlocked `
            -LogFileName $etat.LogFileName `
            -LogMaxSizeKilobytes $etat.LogMaxSizeKilobytes `
            -ErrorAction Stop
    }
}

function Convert-EtatJournal {
    param([object]$Valeur)
    # NetSecurity enums become numbers in JSON; keep all three states distinct.
    switch (("$Valeur").Trim().ToLowerInvariant()) {
        'false' { return '0' }
        '0' { return '0' }
        'true' { return '1' }
        '1' { return '1' }
        'notconfigured' { return '2' }
        '2' { return '2' }
        default { throw "Etat de journal inconnu : '$Valeur'." }
    }
}

function Assert-EtatProfils {
    param(
        [object[]]$Attendus,
        [ValidateSet("PersistentStore", "ActiveStore")]
        [string]$PolicyStore
    )
    $actuels = Get-EtatProfils -PolicyStore $PolicyStore
    foreach ($attendu in $Attendus) {
        $actuel = @($actuels | Where-Object { $_.Name -eq $attendu.Name })
        if ($actuel.Count -ne 1) {
            throw "Profil pare-feu absent ou ambigu apres modification : $($attendu.Name)."
        }
        foreach ($champ in @("LogAllowed", "LogBlocked", "LogFileName", "LogMaxSizeKilobytes")) {
            $valeurActuelle = "$($actuel[0].$champ)"
            $valeurAttendue = "$($attendu.$champ)"
            if ($champ -in @("LogAllowed", "LogBlocked")) {
                $valeurActuelle = Convert-EtatJournal -Valeur $actuel[0].$champ
                $valeurAttendue = Convert-EtatJournal -Valeur $attendu.$champ
            }
            if ($champ -eq "LogFileName") {
                $valeurActuelle = [Environment]::ExpandEnvironmentVariables($valeurActuelle)
                $valeurAttendue = [Environment]::ExpandEnvironmentVariables($valeurAttendue)
            }
            if (-not [string]::Equals($valeurActuelle, $valeurAttendue, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Etat non confirme dans $PolicyStore pour $($attendu.Name).$champ : attendu '$($attendu.$champ)', lu '$($actuel[0].$champ)'."
            }
        }
    }
}

if ($ActiverJournal) {
    if (Test-Path -LiteralPath $EtatJournal) {
        throw "Sauvegarde deja presente : $EtatJournal. Restaurer avec -DesactiverJournal avant une nouvelle activation."
    }
    $localAvant = @(Get-EtatProfils -PolicyStore PersistentStore)
    $effectifAvant = @(Get-EtatProfils -PolicyStore ActiveStore)
    $dossierEtat = Split-Path -Parent $EtatJournal
    New-Item -ItemType Directory -Path $dossierEtat -Force | Out-Null
    $sauvegarde = [PSCustomObject]@{
        FormatVersion = 2
        DateHeure = (Get-Date).ToString("s")
        LocalPersistentAvant = $localAvant
        EffectifActiveAvant = $effectifAvant
    }
    $sauvegarde | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EtatJournal -Encoding UTF8
    try {
        foreach ($profil in $localAvant) {
            Set-NetFirewallProfile -PolicyStore PersistentStore -Name $profil.Name `
                -LogAllowed True -LogBlocked True `
                -LogFileName $CheminJournalActif -LogMaxSizeKilobytes 32767 -ErrorAction Stop
        }
        $attendu = @($localAvant | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                LogAllowed = $true
                LogBlocked = $true
                LogFileName = $CheminJournalActif
                LogMaxSizeKilobytes = 32767
            }
        })
        Assert-EtatProfils -Attendus $attendu -PolicyStore PersistentStore
        Assert-EtatProfils -Attendus $attendu -PolicyStore ActiveStore
    }
    catch {
        $erreurActivation = $_.Exception.Message
        $restauration = "reussie"
        try {
            Set-EtatProfils -Etats $localAvant
            Assert-EtatProfils -Attendus $localAvant -PolicyStore PersistentStore
            Assert-EtatProfils -Attendus $effectifAvant -PolicyStore ActiveStore
        }
        catch {
            $restauration = "non confirmee : $($_.Exception.Message)"
        }
        throw "Activation du journal non confirmee; restauration $restauration. Sauvegarde conservee : $EtatJournal. Erreur initiale : $erreurActivation"
    }
    Write-Host "Journal active et confirme dans PersistentStore et ActiveStore sur les trois profils."
    Write-Host "Etat anterieur sauvegarde dans : $EtatJournal"
    Write-Host "Apres la seance : .\regles-pare-feu.ps1 -DesactiverJournal"
    return
}

if ($DesactiverJournal) {
    if (-not (Test-Path -LiteralPath $EtatJournal)) {
        throw "Aucune sauvegarde a restaurer : $EtatJournal. Aucun profil n'a ete modifie."
    }
    $sauvegarde = Get-Content -LiteralPath $EtatJournal -Raw -ErrorAction Stop | ConvertFrom-Json
    if ("$($sauvegarde.FormatVersion)" -ne "2") {
        throw "Sauvegarde incompatible ou ancienne (FormatVersion=2 requis). Aucun profil n'a ete modifie."
    }
    $localAvant = @($sauvegarde.LocalPersistentAvant)
    $effectifAvant = @($sauvegarde.EffectifActiveAvant)
    foreach ($lot in @($localAvant, $effectifAvant)) {
        $nomsSauves = @($lot | ForEach-Object { "$($_.Name)" } | Sort-Object)
        if (($nomsSauves -join ",") -ne "Domain,Private,Public") {
            throw "Sauvegarde invalide : profils lus '$($nomsSauves -join ', ')'. Domain, Private et Public sont requis. Aucun profil n'a ete modifie."
        }
    }
    Set-EtatProfils -Etats $localAvant
    Assert-EtatProfils -Attendus $localAvant -PolicyStore PersistentStore
    Assert-EtatProfils -Attendus $effectifAvant -PolicyStore ActiveStore
    Remove-Item -LiteralPath $EtatJournal -Force
    Write-Host "Etat local anterieur restaure; etat effectif anterieur confirme sur les trois profils."
    return
}

function Get-ReglesGerees {
    return @(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop |
        Where-Object { $_.Name -like "$PrefixeRegle*" })
}

if ($Retirer) {
    $existantes = Get-ReglesGerees
    foreach ($regle in $existantes) {
        Remove-NetFirewallRule -Name $regle.Name -ErrorAction Stop
        Write-Host "Regle retiree : $($regle.Name)"
    }
    $reste = Get-ReglesGerees
    if ($reste.Count -ne 0) {
        throw "$($reste.Count) regle(s) geree(s) subsistent apres le retrait."
    }
    Write-Host "Retrait confirme : aucune regle geree ne subsiste."
    return
}

function Get-RacineInstallation {
    param([string]$CheminExe)
    $chemin = (Resolve-Path -LiteralPath $CheminExe -ErrorAction Stop).Path
    if ([IO.Path]::GetExtension($chemin) -ne ".exe") {
        throw "Le chemin confirme n'est pas un .exe : $chemin"
    }
    $racine = Split-Path -Parent $chemin
    if ((Split-Path -Leaf $racine) -like "app-*") {
        $racine = Split-Path -Parent $racine
    }
    return $racine
}

function Get-ExecutablesApplication {
    param(
        [string]$Etiquette,
        [string]$MotifProcessus,
        [string[]]$CheminsCandidats,
        [string]$CheminImpose
    )

    $pointsEntree = @()
    if ($CheminImpose) {
        if (-not (Test-Path -LiteralPath $CheminImpose -PathType Leaf)) {
            throw "$Etiquette : chemin impose introuvable : $CheminImpose"
        }
        $pointsEntree += $CheminImpose
    }
    else {
        foreach ($processus in (Get-Process -ErrorAction Stop)) {
            if ($processus.ProcessName -notmatch $MotifProcessus) { continue }
            try {
                if ($processus.Path) { $pointsEntree += $processus.Path }
            }
            catch { }
        }
        $pointsEntree += @($CheminsCandidats | Where-Object {
            $_ -and (Test-Path -LiteralPath $_ -PathType Leaf)
        })
    }

    $racines = @($pointsEntree | ForEach-Object { Get-RacineInstallation $_ } | Sort-Object -Unique)
    if ($racines.Count -eq 0) {
        throw "$Etiquette : aucun dossier d'installation confirme. Lancer l'application ou passer son chemin exact."
    }

    $executables = @()
    foreach ($racine in $racines) {
        Write-Host "$Etiquette - dossier confirme : $racine"
        $executables += @(Get-ChildItem -LiteralPath $racine -Filter "*.exe" -File -Recurse -ErrorAction Stop |
            ForEach-Object { $_.FullName })
    }
    $executables = @($executables | Sort-Object -Unique)
    if ($executables.Count -eq 0) {
        throw "$Etiquette : aucun .exe sous le dossier confirme."
    }
    return $executables
}

function Get-HashChemin {
    param([string]$Chemin)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $octets = [Text.Encoding]::UTF8.GetBytes($Chemin.ToLowerInvariant())
        $empreinte = $sha.ComputeHash($octets)
        return (-join ($empreinte[0..5] | ForEach-Object { $_.ToString("x2") }))
    }
    finally { $sha.Dispose() }
}

$applications = @(
    [PSCustomObject]@{
        Nom = "LMStudio"; Motif = "LM.?Studio"; Impose = $CheminLMStudio
        Candidats = @(
            "$env:LOCALAPPDATA\Programs\lm-studio\LM Studio.exe",
            "$env:LOCALAPPDATA\Programs\LM Studio\LM Studio.exe",
            "$env:ProgramFiles\LM Studio\LM Studio.exe"
        )
    },
    [PSCustomObject]@{
        Nom = "AnythingLLM"; Motif = "AnythingLLM"; Impose = $CheminAnythingLLM
        Candidats = @(
            "$env:LOCALAPPDATA\Programs\AnythingLLM\AnythingLLM.exe",
            "$env:LOCALAPPDATA\Programs\anythingllm-desktop\AnythingLLM.exe",
            "$env:ProgramFiles\AnythingLLM\AnythingLLM.exe"
        )
    }
)

$desirees = @()
foreach ($app in $applications) {
    $executables = @(Get-ExecutablesApplication -Etiquette $app.Nom `
        -MotifProcessus $app.Motif -CheminsCandidats $app.Candidats -CheminImpose $app.Impose)
    Write-Host "$($app.Nom) : $($executables.Count) executable(s) confirme(s)"
    foreach ($exe in $executables) {
        $nom = "$PrefixeRegle$($app.Nom)-$(Get-HashChemin $exe)"
        $desirees += [PSCustomObject]@{ App = $app.Nom; Nom = $nom; Chemin = $exe }
        Write-Host "  $nom -> $exe"
    }
}

$existantes = Get-ReglesGerees
Write-Host "Regles gerees deja presentes : $($existantes.Count)"
if ($Lister) {
    Write-Host "Mode -Lister : rien n'a ete modifie."
    return
}

$nomsDesires = @($desirees | ForEach-Object { $_.Nom })
foreach ($regle in $existantes) {
    if ($nomsDesires -notcontains $regle.Name) {
        Remove-NetFirewallRule -Name $regle.Name -ErrorAction Stop
        Write-Host "Regle perimee retiree : $($regle.Name)"
    }
}

foreach ($cible in $desirees) {
    # Toujours lire l'ActiveStore avec ErrorAction=Stop. Un echec de lecture ne
    # doit jamais etre pris pour l'absence d'une regle.
    $regle = @(Get-ReglesGerees | Where-Object { $_.Name -eq $cible.Nom })
    $recreer = $true
    if ($regle.Count -eq 1) {
        $filtre = @(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $regle[0] -ErrorAction Stop)
        $bonChemin = (
            $filtre.Count -eq 1 -and
            [string]::Equals($filtre[0].Program, $cible.Chemin, [StringComparison]::OrdinalIgnoreCase)
        )
        $bonneRegle = (
            "$($regle[0].Enabled)" -eq "True" -and
            "$($regle[0].Direction)" -eq "Outbound" -and
            "$($regle[0].Action)" -eq "Block" -and
            "$($regle[0].Profile)" -eq "Any"
        )
        if ($bonChemin -and $bonneRegle) { $recreer = $false }
        else { Remove-NetFirewallRule -Name $cible.Nom -ErrorAction Stop }
    }
    elseif ($regle.Count -gt 1) {
        Remove-NetFirewallRule -Name $cible.Nom -ErrorAction Stop
    }

    if ($recreer) {
        New-NetFirewallRule -Name $cible.Nom -DisplayName $cible.Nom `
            -Direction Outbound -Program $cible.Chemin -Action Block -Profile Any `
            -Enabled True -ErrorAction Stop `
            -Description "BUILD AND MIND - VID-002 - trafic sortant bloque pour $($cible.App). Retrait : regles-pare-feu.ps1 -Retirer" |
            Out-Null
    }

    $confirmee = @(Get-ReglesGerees | Where-Object { $_.Name -eq $cible.Nom })
    if ($confirmee.Count -ne 1) {
        throw "Regle absente ou ambigue apres pose : $($cible.Nom)"
    }
    $filtreConfirme = @(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $confirmee[0] -ErrorAction Stop)
    $filtreValide = (
        $filtreConfirme.Count -eq 1 -and
        [string]::Equals($filtreConfirme[0].Program, $cible.Chemin, [StringComparison]::OrdinalIgnoreCase)
    )
    $regleValide = (
        "$($confirmee[0].Enabled)" -eq "True" -and
        "$($confirmee[0].Direction)" -eq "Outbound" -and
        "$($confirmee[0].Action)" -eq "Block" -and
        "$($confirmee[0].Profile)" -eq "Any"
    )
    if (-not $filtreValide -or -not $regleValide) {
        throw "Regle non confirmee apres pose : $($cible.Nom)"
    }
    Write-Host "Regle confirmee : $($cible.Nom) -> $($cible.Chemin)"
}

$finales = Get-ReglesGerees
if ($finales.Count -ne $desirees.Count) {
    throw "Lot incomplet : $($desirees.Count) regle(s) attendue(s), $($finales.Count) presente(s)."
}
Write-Host "Lot confirme : $($finales.Count) regle(s) sortante(s) actives."
Write-Host "Retrait complet : .\regles-pare-feu.ps1 -Retirer"
