<#
.SYNOPSIS
    Observe les connexions TCP distantes et les sockets UDP, puis extrait les
    lignes SEND ajoutees au journal du Pare-feu Windows Defender.

.DESCRIPTION
    Sert a observer quatre situations : conversation locale, telechargement, recherche web, repos. La phase a toujours
    une duree finie. Un prevol verifie les cmdlets, le journal et les profils;
    une erreur de collecte ou une interruption produit un statut INVALIDE,
    jamais un faux resultat zero.

    LIMITES A CONSERVER DANS TOUTE PREUVE :
      - Get-NetTCPConnection ne fournit pas le sens. Ses lignes sont des
        connexions avec une destination distante, pas une preuve de trafic
        sortant. Une connexion entrante acceptee peut apparaitre.
      - Get-NetUDPEndpoint ne fournit que le socket local, sans destination.
      - les lignes SEND du journal pare-feu prouvent un trafic sortant a
        l'echelle de la machine, mais ne contiennent pas le processus.
      - les deux releves sont complementaires; ils ne permettent pas
        d'attribuer une ligne pare-feu UDP ou breve a une application donnee.
      - la portee "non-local" signifie seulement hors boucle locale et plages
        privees reconnues. Elle peut inclure multicast, broadcast ou une plage
        speciale et ne prouve pas qu'une adresse est routable sur Internet.

    Le journal pare-feu est lu par position logique : le script compte les
    lignes avant la phase et n'analyse que les lignes ajoutees ensuite. Il lit
    le champ `#Fields:` au lieu de supposer un ordre de colonnes.

.PARAMETER Etiquette
    Nom de la phase, utilise dans les noms de fichiers.

.PARAMETER DureeSecondes
    Duree finie de la phase. Par defaut : 120 secondes.

.PARAMETER IntervalleMs
    Intervalle entre deux echantillons TCP/UDP. Par defaut : 1000 ms.

.PARAMETER JournalPareFeu
    Exige un journal actif et lisible sur les trois profils, puis extrait les
    lignes SEND ajoutees pendant la phase.

.PARAMETER ExigerPareFeuSend
    Rend la phase invalide si aucune ligne SEND distante n'est relevee. Sert au
    controle positif et aux actions reseau annoncees; ne pas l'utiliser quand
    l'absence d'evenement pendant la fenetre est un resultat possible.

.EXAMPLE
    .\surveiller-connexions.ps1 -Etiquette "controle-positif" -DureeSecondes 60 -JournalPareFeu -ExigerPareFeuSend
    .\surveiller-connexions.ps1 -Etiquette "chat-local" -DureeSecondes 120 -JournalPareFeu
    .\surveiller-connexions.ps1 -Etiquette "telechargement" -DureeSecondes 900 -JournalPareFeu -ExigerPareFeuSend
    .\surveiller-connexions.ps1 -Etiquette "repos" -DureeSecondes 600 -JournalPareFeu

.NOTES
    Verifier la compatibilite avec la version de PowerShell installee avant
    utilisation. Fichier volontairement en ASCII pur pour PowerShell 5.1.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Etiquette,

    [ValidateRange(1, 86400)]
    [int]$DureeSecondes = 120,

    [ValidateRange(100, 60000)]
    [int]$IntervalleMs = 1000,

    [switch]$JournalPareFeu,

    [switch]$ExigerPareFeuSend,

    [string]$CheminJournalPareFeu = "$env:SystemRoot\system32\LogFiles\Firewall\pfirewall.log",

    [string]$SortieDir = "$PSScriptRoot\..\mesures"
)

$ErrorActionPreference = "Stop"
if ($ExigerPareFeuSend -and -not $JournalPareFeu) {
    throw "-ExigerPareFeuSend demande aussi -JournalPareFeu."
}
$etiquetteFichier = ($Etiquette -replace "[^A-Za-z0-9._-]", "-").Trim("-")
if (-not $etiquetteFichier) { throw "Etiquette inutilisable comme nom de fichier." }

New-Item -ItemType Directory -Path $SortieDir -Force | Out-Null
$horodatage = Get-Date -Format "yyyyMMdd-HHmmss"
$journalCsv = Join-Path $SortieDir "reseau-$etiquetteFichier-$horodatage-tcp.csv"
$journalUdp = Join-Path $SortieDir "reseau-$etiquetteFichier-$horodatage-udp.csv"
$journalPf = Join-Path $SortieDir "reseau-$etiquetteFichier-$horodatage-parefeu.csv"
$journalStatut = Join-Path $SortieDir "reseau-$etiquetteFichier-$horodatage-statut.txt"

function Get-Portee {
    param([string]$Adresse)
    if (-not $Adresse) { return "inconnue" }
    $normalisee = $Adresse.Trim([char[]]"[]")
    if ($normalisee -match "^::ffff:(?<ipv4>[0-9]+(?:\.[0-9]+){3})$") {
        $normalisee = $Matches.ipv4
    }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($normalisee, [ref]$ip)) { return "inconnue" }
    if ($normalisee -eq "::1" -or $normalisee.StartsWith("127.")) { return "boucle-locale" }
    if ($normalisee -eq "0.0.0.0" -or $normalisee -eq "::") { return "non-attribuee" }
    if (
        $normalisee.StartsWith("10.") -or
        $normalisee.StartsWith("192.168.") -or
        $normalisee.StartsWith("169.254.")
    ) { return "reseau-local" }
    if (
        $normalisee -match "^172\.(\d+)\." -and
        [int]$Matches[1] -ge 16 -and
        [int]$Matches[1] -le 31
    ) {
        return "reseau-local"
    }
    if ($normalisee -match "^fe[89ab]" -or $normalisee -match "^f[cd]") { return "reseau-local" }
    return "non-local"
}

function Ajouter-Ligne {
    param([PSCustomObject]$Ligne, [string]$Fichier)
    if (Test-Path -LiteralPath $Fichier) {
        $Ligne | Export-Csv -LiteralPath $Fichier -NoTypeInformation -Encoding UTF8 -Append
    }
    else {
        $Ligne | Export-Csv -LiteralPath $Fichier -NoTypeInformation -Encoding UTF8
    }
}

function Get-ChampsPareFeu {
    param([string[]]$Lignes)
    $entete = @($Lignes | Where-Object { $_ -like "#Fields:*" } | Select-Object -Last 1)
    if ($entete.Count -ne 1) { throw "Entete #Fields introuvable dans le journal pare-feu." }
    $champs = @($entete[0].Substring(8).Trim() -split "\s+")
    foreach ($requis in @("date", "time", "action", "protocol", "dst-ip", "dst-port", "path")) {
        if ($champs -notcontains $requis) { throw "Champ pare-feu requis absent : $requis" }
    }
    return $champs
}

function Get-IndexChamps {
    param([string[]]$Champs)
    $index = @{}
    for ($i = 0; $i -lt $Champs.Count; $i++) { $index[$Champs[$i]] = $i }
    return $index
}

# Prevol : l'absence de droit ou de cmdlet doit arreter avant toute conclusion.
try {
    @(Get-NetTCPConnection -ErrorAction Stop | Select-Object -First 1) | Out-Null
    @(Get-NetUDPEndpoint -ErrorAction Stop | Select-Object -First 1) | Out-Null
}
catch {
    throw "Prevol TCP/UDP impossible; aucune mesure n'a ete faite : $($_.Exception.Message)"
}

$nombreLignesPareFeuAvant = 0
$champsPareFeu = @()
if ($JournalPareFeu) {
    try {
        $profils = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
        $nomsProfils = @($profils | ForEach-Object { "$($_.Name)" } | Sort-Object)
        if (($nomsProfils -join ",") -ne "Domain,Private,Public") {
            throw "Profils inattendus : $($nomsProfils -join ', '). Domain, Private et Public sont requis."
        }
        $cheminAttendu = [Environment]::ExpandEnvironmentVariables($CheminJournalPareFeu)
        foreach ($profil in $profils) {
            if ("$($profil.LogAllowed)" -ne "True" -or "$($profil.LogBlocked)" -ne "True") {
                throw "Journal incomplet sur le profil $($profil.Name) : LogAllowed et LogBlocked doivent etre True."
            }
            $cheminProfil = [Environment]::ExpandEnvironmentVariables("$($profil.LogFileName)")
            if (-not [string]::Equals($cheminProfil, $cheminAttendu, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Le profil $($profil.Name) ecrit dans '$cheminProfil', pas dans '$cheminAttendu'."
            }
        }
        if (Test-Path -LiteralPath $cheminAttendu -PathType Leaf) {
            $avantPareFeu = @(Get-Content -LiteralPath $cheminAttendu -ErrorAction Stop)
            $entetesAvant = @($avantPareFeu | Where-Object { $_ -like "#Fields:*" })
            if ($entetesAvant.Count -gt 0) {
                $champsPareFeu = @(Get-ChampsPareFeu -Lignes $avantPareFeu)
            }
        }
        else {
            # Un journal tout juste active peut n'etre cree qu'au premier
            # evenement. Le controle positif devra creer le fichier et son
            # entete; l'extraction finale refusera sinon la phase.
            $avantPareFeu = @()
        }
        $nombreLignesPareFeuAvant = $avantPareFeu.Count
        $CheminJournalPareFeu = $cheminAttendu
    }
    catch {
        throw "Prevol du journal pare-feu impossible; aucune mesure n'a ete faite : $($_.Exception.Message)"
    }
}

$dejaVu = [Collections.Generic.HashSet[string]]::new()
$dejaVuUdp = [Collections.Generic.HashSet[string]]::new()
$nbLignes = 0
$nbLignesUdp = 0
$echantillonsReussis = 0
$termineNormalement = $false
$erreurCollecte = ""
$debut = Get-Date

Write-Host "Phase '$Etiquette' : $DureeSecondes s, intervalle $IntervalleMs ms."
Write-Host "TCP : connexions distantes, sens non determine. Pare-feu SEND : sortant machine, processus inconnu."

try {
    while ((Get-Date) -lt $debut.AddSeconds($DureeSecondes)) {
        try {
            $connexions = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object {
                $_.State -ne "Listen" -and $_.State -ne "Bound" -and
                (Get-Portee $_.RemoteAddress) -ne "non-attribuee"
            })
            $udp = @(Get-NetUDPEndpoint -ErrorAction Stop)
            $echantillonsReussis++
        }
        catch {
            $erreurCollecte = $_.Exception.Message
            throw "Collecte interrompue; phase invalide : $erreurCollecte"
        }

        foreach ($c in $connexions) {
            $cle = "$($c.OwningProcess)|$($c.RemoteAddress)|$($c.RemotePort)|$($c.State)"
            if (-not $dejaVu.Add($cle)) { continue }
            $nomProcessus = "non attribue (pid $($c.OwningProcess), $($c.State))"
            $cheminProcessus = ""
            try {
                $processus = Get-Process -Id $c.OwningProcess -ErrorAction Stop
                $nomProcessus = $processus.ProcessName
                try { $cheminProcessus = $processus.Path } catch { }
            }
            catch { }

            $ligne = [PSCustomObject]@{
                Horodatage = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Phase = $Etiquette
                Protocole = "TCP"
                Sens = "indetermine par Get-NetTCPConnection"
                Processus = $nomProcessus
                Pid = $c.OwningProcess
                Chemin = $cheminProcessus
                AdresseDistante = $c.RemoteAddress
                PortDistant = $c.RemotePort
                Portee = (Get-Portee $c.RemoteAddress)
                Etat = $c.State
            }
            Ajouter-Ligne -Ligne $ligne -Fichier $journalCsv
            $nbLignes++
            Write-Host ("[{0}] {1} <-> {2}:{3} [sens TCP indetermine]" -f `
                $ligne.Horodatage, $nomProcessus, $c.RemoteAddress, $c.RemotePort)
        }

        foreach ($u in $udp) {
            $cleU = "$($u.OwningProcess)|$($u.LocalAddress)|$($u.LocalPort)"
            if (-not $dejaVuUdp.Add($cleU)) { continue }
            $nomU = "non attribue (pid $($u.OwningProcess))"
            try { $nomU = (Get-Process -Id $u.OwningProcess -ErrorAction Stop).ProcessName } catch { }
            Ajouter-Ligne -Fichier $journalUdp -Ligne ([PSCustomObject]@{
                Horodatage = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Phase = $Etiquette
                Protocole = "UDP"
                Processus = $nomU
                Pid = $u.OwningProcess
                AdresseLocale = $u.LocalAddress
                PortLocal = $u.LocalPort
                Remarque = "socket local seulement; aucune destination ni preuve de trafic"
            })
            $nbLignesUdp++
        }
        Start-Sleep -Milliseconds $IntervalleMs
    }
    $termineNormalement = $true
}
finally {
    $fin = Get-Date
    $statut = "INVALIDE"
    $raisonStatut = "phase interrompue avant sa duree declaree"
    if ($erreurCollecte) { $raisonStatut = "erreur de collecte : $erreurCollecte" }
    elseif ($termineNormalement -and $echantillonsReussis -gt 0) {
        $statut = "VALIDE"
        $raisonStatut = "$echantillonsReussis echantillon(s) TCP/UDP reussi(s)"
    }

    $lignesPareFeuRetenues = @()
    $erreurPareFeu = ""
    if ($JournalPareFeu) {
        try {
            $apresPareFeu = @(Get-Content -LiteralPath $CheminJournalPareFeu -ErrorAction Stop)
            if ($apresPareFeu.Count -lt $nombreLignesPareFeuAvant) {
                throw "Le journal a ete tronque ou remplace pendant la phase."
            }
            for ($i = 0; $i -lt $nombreLignesPareFeuAvant; $i++) {
                if ($apresPareFeu[$i] -cne $avantPareFeu[$i]) {
                    throw "Le journal a ete reecrit ou remplace pendant la phase."
                }
            }
            $champsPareFeu = @(Get-ChampsPareFeu -Lignes $apresPareFeu)
            $index = Get-IndexChamps -Champs $champsPareFeu
            $nouvelles = @($apresPareFeu | Select-Object -Skip $nombreLignesPareFeuAvant)
            foreach ($texte in $nouvelles) {
                if (-not $texte -or $texte.StartsWith("#")) { continue }
                $valeurs = @($texte -split "\s+")
                if ($valeurs.Count -lt $champsPareFeu.Count) {
                    throw "Ligne pare-feu incomplete : $texte"
                }
                if ($valeurs[$index["path"]] -ne "SEND") { continue }
                $adresse = $valeurs[$index["dst-ip"]]
                $portee = Get-Portee $adresse
                if ($portee -eq "boucle-locale" -or $portee -eq "non-attribuee") { continue }
                $lignesPareFeuRetenues += [PSCustomObject]@{
                    Horodatage = "$($valeurs[$index['date']]) $($valeurs[$index['time']])"
                    Phase = $Etiquette
                    Action = $valeurs[$index["action"]]
                    Protocole = $valeurs[$index["protocol"]]
                    Sens = "sortant (SEND), machine entiere"
                    Processus = "non fourni par le journal pare-feu"
                    AdresseDistante = $adresse
                    PortDistant = $valeurs[$index["dst-port"]]
                    Portee = $portee
                }
            }
            if ($lignesPareFeuRetenues.Count -gt 0) {
                $lignesPareFeuRetenues | Export-Csv -LiteralPath $journalPf -NoTypeInformation -Encoding UTF8
            }
            if ($ExigerPareFeuSend -and $lignesPareFeuRetenues.Count -eq 0) {
                $statut = "INVALIDE"
                $raisonStatut = "controle positif sans ligne pare-feu SEND distante"
            }
            elseif ($statut -eq "VALIDE" -and $lignesPareFeuRetenues.Count -eq 0) {
                "Aucune ligne SEND distante ajoutee au journal pare-feu pendant la phase complete '$Etiquette'." |
                    Set-Content -LiteralPath $journalPf -Encoding UTF8
            }
        }
        catch {
            $erreurPareFeu = $_.Exception.Message
            $statut = "INVALIDE"
            $raisonStatut = "journal pare-feu inexploitable : $erreurPareFeu"
        }
    }

    if ($statut -eq "VALIDE" -and $nbLignes -eq 0) {
        "Aucune connexion TCP distante observee pendant la phase complete '$Etiquette'. Sens TCP non determine; consulter le journal pare-feu SEND." |
            Set-Content -LiteralPath $journalCsv -Encoding UTF8
    }

    @(
        "Statut=$statut"
        "Phase=$Etiquette"
        "Debut=$($debut.ToString('s'))"
        "Fin=$($fin.ToString('s'))"
        "DureeDemandeeSecondes=$DureeSecondes"
        "EchantillonsReussis=$echantillonsReussis"
        "LignesTcp=$nbLignes"
        "SocketsUdp=$nbLignesUdp"
        "LignesPareFeuSend=$($lignesPareFeuRetenues.Count)"
        "Raison=$raisonStatut"
        "LimiteTcp=Get-NetTCPConnection ne fournit pas le sens"
        "LimitePareFeu=SEND est global a la machine et sans processus"
        "LimitePortee=non-local ne signifie pas Internet; multicast, broadcast et plages speciales restent possibles"
    ) | Set-Content -LiteralPath $journalStatut -Encoding UTF8

    Write-Host "Statut : $statut - $raisonStatut"
    Write-Host "Statut detaille : $journalStatut"
    if ($statut -eq "VALIDE") {
        Write-Host "TCP distant : $nbLignes ligne(s); UDP local : $nbLignesUdp socket(s); pare-feu SEND : $($lignesPareFeuRetenues.Count) ligne(s)."
    }
    else {
        Write-Warning "Ne reporter aucun zero ni aucune absence de trafic pour cette phase."
    }
}

if ($statut -ne "VALIDE") {
    throw "Phase reseau invalide : $raisonStatut"
}
