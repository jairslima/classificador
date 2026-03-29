[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Query,
    [switch]$Refresh,
    [switch]$ListCategories,
    [string]$Root,
    [switch]$RegisterRoot
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir "config.json"
$OverridesPath = Join-Path $ScriptDir "overrides.json"

function Normalize-Text([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $d = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return ([regex]::Replace($sb.ToString().ToLowerInvariant(), "[^a-z0-9]+", " ")).Trim()
}

function Slug([string]$Text) {
    return ([regex]::Replace((Normalize-Text $Text), "\s+", "_")).Trim("_")
}

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-Json([string]$Path, [object]$Data) {
    Set-Content -LiteralPath $Path -Value ($Data | ConvertTo-Json -Depth 20) -Encoding UTF8
}

function Get-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { Save-Json $ConfigPath @{ roots = @() } }
    $cfg = Read-Json $ConfigPath
    if (-not $cfg.roots) { $cfg.roots = @() }
    return $cfg
}

function Add-RootToConfig([string]$Path) {
    $cfg = Get-Config
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    if (-not ($cfg.roots -contains $resolved)) {
        $cfg.roots += $resolved
        Save-Json $ConfigPath $cfg
    }
    $resolved
}

function Get-Overrides {
    $raw = Read-Json $OverridesPath
    if (-not $raw) { return @{} }
    $map = @{}
    foreach ($prop in $raw.PSObject.Properties) {
        $map[$prop.Name] = $prop.Value
    }
    return $map
}

function Support-File([string]$Name) {
    $n = Normalize-Text $Name
    return $n -match "(resenha|sinopse|prefa|transcri|esboco|indice|anexo|formulario|certificado|isbn|depoimento|critica|protocolo|recomend|apresentacao|pesquisa)"
}

function Support-Folder([string]$Name) {
    $n = Normalize-Text $Name
    return $n -in @("imagens","capas","edital","teste","livro de bolso","primeira edicao","outras biblias","mae 1","a cronologia biblica 413")
}

function Direct-Docs([string]$Path) {
    @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in ".doc",".docx" -and $_.Name -notmatch '^~\$'
    })
}

function Score-Doc($File, [string]$FolderName) {
    $name = Normalize-Text $File.BaseName
    $score = 0
    if (-not (Support-File $File.BaseName)) { $score += 3 }
    if ($name -match "(livro|guia|manual|cronologia|biblia|bibl|teologia|jesus|casamento|familia|devocional|comentario|dicionario|romance|salmos|apocalipse)") { $score += 2 }
    foreach ($token in ((Normalize-Text $FolderName) -split " " | Where-Object { $_.Length -ge 4 })) {
        if ($name -match ("\b" + [regex]::Escape($token) + "\b")) { $score += 1 }
    }
    if ($File.Extension -eq ".docx") { $score += 1 }
    if ($File.Length -gt 200KB) { $score += 2 } elseif ($File.Length -gt 50KB) { $score += 1 }
    $score
}

function Project-Folders([string]$RootPath) {
    $dirs = @((Get-Item -LiteralPath $RootPath)) + @(Get-ChildItem -LiteralPath $RootPath -Recurse -Directory -Force)
    $out = foreach ($dir in $dirs) {
        $docs = Direct-Docs $dir.FullName
        if (-not $docs.Count) { continue }
        $scores = @($docs | ForEach-Object { [PSCustomObject]@{ File = $_; Score = Score-Doc $_ $dir.Name } } | Sort-Object Score, @{Expression={$_.File.Length}} -Descending)
        $best = if ($scores) { $scores[0].Score } else { 0 }
        $parent = Split-Path -Parent $dir.FullName
        $parentHasDocs = $parent -and (Direct-Docs $parent).Count -gt 0
        $isProject = $best -ge 4 -or (-not $parentHasDocs -and -not (Support-Folder $dir.Name))
        if ((Support-Folder $dir.Name) -and $parentHasDocs) { $isProject = $false }
        if ($isProject) { [PSCustomObject]@{ Path = $dir.FullName; Ranked = $scores } }
    }
    @($out | Sort-Object Path)
}

function Primary-Files($Project) {
    $top = if ($Project.Ranked) { $Project.Ranked[0].Score } else { 0 }
    $primary = @($Project.Ranked | Where-Object { $_.Score -ge [Math]::Max(4, $top - 1) } | Select-Object -ExpandProperty File)
    if (-not $primary.Count) { $primary = @($Project.Ranked[0].File) }
    $primary
}

function Docx-Snippet([string]$Path) {
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -ne ".docx") { return "" }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        $entry = $zip.GetEntry("word/document.xml")
        if (-not $entry) { return "" }
        $reader = New-Object IO.StreamReader($entry.Open())
        $xml = $reader.ReadToEnd(); $reader.Close()
        $text = [regex]::Replace($xml, "<[^>]+>", " ")
        $text = [System.Net.WebUtility]::HtmlDecode($text)
        $text = [regex]::Replace($text, "\s+", " ").Trim()
        if ($text.Length -gt 900) { $text.Substring(0,900) } else { $text }
    } catch { "" } finally { if ($zip) { $zip.Dispose() } }
}

function Docx-FullText([string]$Path) {
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -ne ".docx") { return "" }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        $entry = $zip.GetEntry("word/document.xml")
        if (-not $entry) { return "" }
        $reader = New-Object IO.StreamReader($entry.Open())
        $xml = $reader.ReadToEnd(); $reader.Close()
        $text = [regex]::Replace($xml, "<[^>]+>", " ")
        $text = [System.Net.WebUtility]::HtmlDecode($text)
        [regex]::Replace($text, "\s+", " ").Trim()
    } catch { "" } finally { if ($zip) { $zip.Dispose() } }
}

function Category-Labels {
    @{
        casais="Casais"; familias="Famílias"; mulheres="Mulheres"; homens="Homens"; jovens="Jovens"; criancas="Crianças"; lideres="Líderes"; pastores="Pastores"; pregadores="Pregadores"; igreja="Igreja"; estudiosos="Estudiosos";
        casamento="Casamento"; familia="Família"; parentalidade="Parentalidade"; vida_crista="Vida cristã"; devocional="Devocional"; oracao="Oração"; dons_espirituais="Dons espirituais"; teologia_pentecostal="Teologia pentecostal"; teologia_biblica="Teologia bíblica"; escatologia="Escatologia"; comentario_biblico="Comentário bíblico"; personagens_biblicos="Personagens bíblicos"; parabolas="Parábolas"; milagres="Milagres"; biblia_estudo="Estudo da Bíblia"; historia_da_igreja="História da igreja"; bioetica="Bioética"; tecnologia_e_fe="Tecnologia e fé"; evangelismo_digital="Evangelismo digital"; cultura_politica="Cultura e política"; saude_mental="Saúde mental"; dependencias="Dependências"; saude_do_homem="Saúde do homem"; batalha_espiritual="Batalha espiritual"; ficcao_crista="Ficção cristã"; rpg_cristao="RPG cristão"; poesia="Poesia";
        livro="Livro"; guia_pratico="Guia prático"; manual="Manual"; comentario="Comentário"; dicionario="Dicionário"; curso_modular="Curso modular"; infantil="Infantil"; romance="Romance"; ebook="E-book";
        aconselhamento="Aconselhamento"; pregacao="Pregação"; ensino="Ensino bíblico"; discipulado="Discipulado"; ministerio_familia="Ministério de família"; igreja_local="Igreja local";
        lancado="Lançado"; em_andamento="Em andamento"; prefaciado="Prefaciado"
    }
}

function New-List { New-Object 'System.Collections.Generic.List[string]' }
function Add-Once($List,[string]$Value) { if ($Value -and -not $List.Contains($Value)) { $List.Add($Value) } }

function Rule-Map {
    @{
        publico = @{
            casais=@("casamento","casais","esposa","amor conjugal","matrimonio"); familias=@("familia","filhos","lar","mae","pais"); mulheres=@("mulher","mulheres","mae"); homens=@("homem","homens"); jovens=@("jovem","jovens","nova geracao"); criancas=@("infantil","criancas"); lideres=@("lideres","lideranca","pastoral"); pastores=@("pastor","pastores"); pregadores=@("pregador","pregadores","pregacao"); igreja=@("igreja","cristao"); estudiosos=@("teologia","comentario biblico","tratado exeg");
        }
        tema = @{
            casamento=@("casamento","casais","matrimonial","conjugal"); familia=@("familia","lar"); parentalidade=@("filhos","mae","maternidade"); vida_crista=@("vida crista","proposito","extraordinarios de deus"); devocional=@("devocional","mil dias com jesus"); oracao=@("oracao","circulo de oracao","oracoes da biblia"); dons_espirituais=@("dons espirituais","espirito santo"); teologia_pentecostal=@("pentecostal","assembleia de deus","assembleias de deus"); teologia_biblica=@("reino de deus","parabolas","evangelhos","teologia"); escatologia=@("apocalipse","nova jerusalem","arrebatamento","escatologia"); comentario_biblico=@("comentario biblico"); personagens_biblicos=@("balaao","joabe","pedro","joquebede","moises","mulheres da biblia","herois da fe"); parabolas=@("parabolas"); milagres=@("milagres","sinais"); biblia_estudo=@("como ler a biblia","cronologia biblica","biblia sagrada","harpa crista"); historia_da_igreja=@("historia das assembleias de deus","jose manuel"); bioetica=@("bioetica","crispr","defesa da vida"); tecnologia_e_fe=@("inteligencia artificial","agi","redes sociais","lgpd","tecnologia"); evangelismo_digital=@("redes sociais","cristao conectado"); cultura_politica=@("evangelico de esquerda"); saude_mental=@("setembro amarelo","depressao","suicidio","burnout"); dependencias=@("jogadores anonimos","ludopatia","vicio"); saude_do_homem=@("novembro azul","saude do homem"); batalha_espiritual=@("batalha espiritual","invisivel","luz e trevas"); ficcao_crista=@("romance","eternidade entrelacada","luz e trevas"); rpg_cristao=@("rpg"); poesia=@("verso","versos");
        }
        formato = @{ guia_pratico=@("guia"); manual=@("manual"); comentario=@("comentario"); dicionario=@("dicionario"); infantil=@("infantil"); romance=@("romance"); ebook=@("ebook") }
        uso = @{ aconselhamento=@("restaura","saude mental","libertacao"); pregacao=@("pregadores","pregacao"); ensino=@("teologia","comentario","como ler a biblia"); discipulado=@("discipulos","apostolos","corpo de cristo"); ministerio_familia=@("casamento","familia","filhos","mae"); igreja_local=@("igreja local","assembleia de deus","circulo de oracao") }
    }
}

function Clean-PersonName([string]$Text) {
    $name = $Text
    $name = $name -replace '\.(doc|docx)$', ''
    $name = $name -replace '(?i)\b(pref[aá]cio|apresenta[cç][aã]o|do livro|livro|para o livro|pr[\.\s]|pastor|pb[\.\s]|rev[\.\s]|dr[\.\s]|dra[\.\s]|bispo|mission[aá]rio|missionaria)\b', ' '
    $name = $name -replace '[_\-;]+', ' '
    $name = [regex]::Replace($name, '\s+', ' ').Trim()
    if ($name.Length -lt 3) { return "" }
    $parts = $name.Split(' ') | Where-Object { $_.Length -ge 2 }
    if (-not $parts.Count) { return "" }
    (($parts | ForEach-Object {
        if ($_.Length -le 3) { $_.ToLowerInvariant() } else { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant() }
    }) -join ' ').Trim()
}

function Is-OwnName([string]$Name) {
    $n = Normalize-Text $Name
    return $n -match '\bjair\b' -and $n -match '\blima\b'
}

function Is-PlausiblePersonName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $normalized = Normalize-Text $Name
    $tokens = @($normalized -split ' ' | Where-Object { $_ })
    if ($tokens.Count -lt 1 -or $tokens.Count -gt 4) { return $false }

    $stopwords = @(
        'conhecimento','todos','aqueles','explorar','valores','fundamentais','mais','contribuicoes','valiosas',
        'esta','esse','essa','como','para','livro','prefacio','prefacio','apresentacao','dedicatoria','uma','por','de',
        'do','da','dos','das','que','com','sem','sobre','aos','aquelas','aquela','aquele','aqueles'
    )

    foreach ($token in $tokens) {
        if ($token.Length -lt 2) { return $false }
        if ($stopwords -contains $token) { return $false }
    }

    return $true
}

function Extract-PersonCandidates([string]$Text) {
    $candidates = New-List
    if ([string]::IsNullOrWhiteSpace($Text)) { return @($candidates) }

    $patterns = @(
        '(?is)(?:pref[aá]cio|apresenta[cç][aã]o|dedicat[oó]ria)\s+(?:por|de)\s+([\p{Lu}][\p{L}]+(?:\s+[\p{Lu}][\p{L}]+){0,4})',
        '(?is)\bpor\s+([\p{Lu}][\p{L}]+(?:\s+[\p{Lu}][\p{L}]+){1,4})',
        '(?is)\bde\s+([\p{Lu}][\p{L}]+(?:\s+[\p{Lu}][\p{L}]+){1,4})'
    )

    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Text, $pattern)) {
            $clean = Clean-PersonName $match.Groups[1].Value
            if ($clean -and (Is-PlausiblePersonName $clean) -and -not (Is-OwnName $clean)) {
                Add-Once $candidates $clean
            }
        }
    }

    $tail = if ($Text.Length -gt 500) { $Text.Substring($Text.Length - 500) } else { $Text }
    foreach ($line in ($tail -split '(?<=[\.\!\?])\s+|\r?\n')) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^[\p{Lu}][\p{L}]+(?:\s+[\p{Lu}][\p{L}]+){1,4}$') {
            $clean = Clean-PersonName $trimmed
            if ($clean -and (Is-PlausiblePersonName $clean) -and -not (Is-OwnName $clean)) {
                Add-Once $candidates $clean
            }
        }
    }

    @($candidates)
}

function Get-Prefaciantes([string]$FolderPath) {
    $files = Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in ".doc",".docx" -and $_.BaseName -match '(?i)pref[aá]cio|apresenta[cç][aã]o|dedicat[oó]ria' }
    $names = New-List
    foreach ($file in $files) {
        $base = $file.BaseName
        $candidates = New-List
        if ($base -match '(?i)apresenta[cç][aã]o do livro por\s+(.+)$') {
            Add-Once $candidates (Clean-PersonName $matches[1])
        } elseif ($base -match '(?i)\bpor\s+(.+)$') {
            Add-Once $candidates (Clean-PersonName $matches[1])
        } elseif ($base -match '(?i)pref[aá]cio(?: do livro)?\s+(.+)$') {
            Add-Once $candidates (Clean-PersonName $matches[1])
        } elseif ($base -match '(?i)^.+?\s+pref[aá]cio\s+(.+)$') {
            Add-Once $candidates (Clean-PersonName $matches[1])
        }

        $docText = Docx-FullText $file.FullName
        foreach ($person in (Extract-PersonCandidates $docText)) {
            Add-Once $candidates $person
        }

        foreach ($candidate in $candidates) {
            if ($candidate -and (Is-PlausiblePersonName $candidate) -and -not (Is-OwnName $candidate)) {
                Add-Once $names $candidate
            }
        }
    }
    @($names | Sort-Object -Unique)
}

function Classify($FolderPath, $PrimaryFiles) {
    $text = @($FolderPath, ($PrimaryFiles | ForEach-Object BaseName)) -join " "
    $n = Normalize-Text $text
    $labels = Category-Labels
    $rules = Rule-Map
    $ov = Get-Overrides
    $slug = Slug (Split-Path -Leaf $FolderPath)
    $cats = @{ publico=(New-List); tema=(New-List); formato=(New-List); uso=(New-List); fase=(New-List); especiais=(New-List) }
    foreach ($dim in $rules.Keys) {
        foreach ($id in $rules[$dim].Keys) {
            foreach ($pattern in $rules[$dim][$id]) {
                $p = Normalize-Text $pattern
                if ($p -and $n -match ("\b" + [regex]::Escape($p) + "\b")) { Add-Once $cats[$dim] $id; break }
            }
        }
    }
    if ($FolderPath -match "Lançado|lançado") { Add-Once $cats.fase "lancado" } else { Add-Once $cats.fase "em_andamento" }
    if ($cats.formato.Count -eq 0) { Add-Once $cats.formato "livro" }
    $summary = "Classificação automática por nome da pasta, arquivos principais e trechos de conteúdo."
    if ($ov.ContainsKey($slug)) {
        $override = $ov[$slug]
        foreach ($dim in $override.Keys) {
            if ($dim -eq "resumo") { $summary = $override[$dim]; continue }
            foreach ($id in $override[$dim]) { Add-Once $cats[$dim] $id }
        }
    }
    $prefaciantes = @(Get-Prefaciantes $FolderPath)
    if ($prefaciantes.Count) { Add-Once $cats.especiais "prefaciado" }
    $keywords = New-List
    foreach ($dim in $cats.Keys) { foreach ($id in $cats[$dim]) { Add-Once $keywords ($labels[$id]) } }
    foreach ($person in $prefaciantes) { Add-Once $keywords $person }
    [ordered]@{
        version = 1
        gerado_em = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        pasta = $FolderPath
        titulo = (Split-Path -Leaf $FolderPath)
        resumo = $summary
        arquivos_principais = @($PrimaryFiles | ForEach-Object FullName)
        arquivos_doc_docx = @(Get-ChildItem -LiteralPath $FolderPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in ".doc",".docx" -and $_.Name -notmatch '^~\$' } | ForEach-Object FullName | Sort-Object -Unique)
        categorias = @{
            publico = @($cats.publico)
            tema = @($cats.tema)
            formato = @($cats.formato)
            uso = @($cats.uso)
            fase = @($cats.fase)
            especiais = @($cats.especiais)
        }
        categorias_rotulos = @{
            publico = @($cats.publico | ForEach-Object { $labels[$_] })
            tema = @($cats.tema | ForEach-Object { $labels[$_] })
            formato = @($cats.formato | ForEach-Object { $labels[$_] })
            uso = @($cats.uso | ForEach-Object { $labels[$_] })
            fase = @($cats.fase | ForEach-Object { $labels[$_] })
            especiais = @($cats.especiais | ForEach-Object { $labels[$_] })
        }
        prefaciado = [bool]$prefaciantes.Count
        prefaciantes = @($prefaciantes)
        palavras_chave = @($keywords)
    }
}

function Write-Classifier([string]$FolderPath, $Data) {
    $target = Join-Path $FolderPath "classificador.md"
    $json = $Data | ConvertTo-Json -Depth 20
    $catLines = foreach ($dim in $Data.categorias_rotulos.Keys) { "- **$dim**: " + ($Data.categorias_rotulos[$dim] -join ", ") }
    $lines = @(
        '# Classificador','','Gerado automaticamente pelo sistema `classificador`.','','## Resumo','','- **Titulo**: ' + $Data.titulo,'- **Pasta**: ' + $Data.pasta,'- **Arquivos principais**: ' + @($Data.arquivos_principais).Count,'- **Arquivos doc/docx**: ' + @($Data.arquivos_doc_docx).Count,'','## Categorias',''
    )
    if ($Data.prefaciado) {
        $lines = $lines[0..9] + @('- **Prefaciado**: Sim','- **Prefaciantes**: ' + ($Data.prefaciantes -join ', '),'') + $lines[10..($lines.Count-1)]
    }
    $lines += $catLines
    $lines += @('','## Palavras-chave','','- ' + ($Data.palavras_chave -join ', '),'','## Dados Estruturados','','```json',$json,'```','')
    $md = $lines -join [Environment]::NewLine
    Set-Content -LiteralPath $target -Value $md -Encoding UTF8 -Force
}

function Build-Root([string]$RootPath, [switch]$OnlyMissing) {
    $created = New-List; $updated = New-List
    foreach ($project in (Project-Folders $RootPath)) {
        $file = Join-Path $project.Path "classificador.md"
        if ($OnlyMissing -and (Test-Path -LiteralPath $file)) { continue }
        $data = Classify $project.Path (Primary-Files $project)
        $exists = Test-Path -LiteralPath $file
        Write-Classifier $project.Path $data
        if ($exists) { Add-Once $updated $file } else { Add-Once $created $file }
    }
    [PSCustomObject]@{ Root=$RootPath; Created=@($created); Updated=@($updated); Projects=@((Project-Folders $RootPath)).Count }
}

function Read-Classifier([string]$Path) {
    $m = [regex]::Match((Get-Content -LiteralPath $Path -Raw -Encoding UTF8), '(?s)```json\s*(\{.*\})\s*```')
    if ($m.Success) { $m.Groups[1].Value | ConvertFrom-Json }
}

function Search-Terms([string]$Text) {
    $n = Normalize-Text $Text
    $terms = New-List; Add-Once $terms $n
    $aliases = @{
        casamento=@("casamento","casais","conjugal","matrimonio"); casais=@("casais","casamento","conjugal"); familia=@("familia","lar","filhos"); jovens=@("jovens","juventude","jovem"); mulheres=@("mulheres","mulher","mae"); homens=@("homens","homem"); pastores=@("pastores","pastor","lideres"); escatologia=@("escatologia","apocalipse","nova jerusalem"); saude_mental=@("saude mental","depressao","suicidio","burnout"); tecnologia=@("tecnologia","ia","inteligencia artificial","redes sociais","agi"); prefaciante=@("prefaciante","prefaciado","prefacio","prefácio"); prefaciado=@("prefaciado","prefaciante","prefacio","prefácio")
    }
    $key = Slug $n
    if ($aliases.ContainsKey($key)) { foreach ($a in $aliases[$key]) { Add-Once $terms (Normalize-Text $a) } }
    @($terms)
}

function Active-Roots {
    if ($Root) { return @((Resolve-Path -LiteralPath $Root).Path) }
    $cfg = Get-Config
    if ($cfg.roots.Count) { return @($cfg.roots) }
    return @((Get-Location).Path)
}

if ($RegisterRoot) { Write-Output ("Raiz registrada: " + (Add-RootToConfig $Root)); exit 0 }

if ($ListCategories) {
    $labels = Category-Labels
    foreach ($id in ($labels.Keys | Sort-Object)) { Write-Output ("- {0} => {1}" -f $id, $labels[$id]) }
    exit 0
}

$roots = Active-Roots
if ([string]::IsNullOrWhiteSpace($Query)) {
    foreach ($r in $roots) {
        $result = Build-Root $r -OnlyMissing:(-not $Refresh)
        Write-Output ("Raiz: " + $result.Root)
        Write-Output ("Pastas de projeto detectadas: " + $result.Projects)
        Write-Output ("Classificadores criados: " + $result.Created.Count)
        Write-Output ("Classificadores atualizados: " + $result.Updated.Count)
        foreach ($item in $result.Created) { Write-Output ("- " + $item) }
        foreach ($item in $result.Updated) { Write-Output ("- " + $item) }
        Write-Output ""
    }
    exit 0
}

$terms = Search-Terms $Query
$hits = New-Object System.Collections.Generic.List[object]
foreach ($r in $roots) {
    foreach ($file in (Get-ChildItem -LiteralPath $r -Recurse -Filter classificador.md -File -ErrorAction SilentlyContinue)) {
        $data = Read-Classifier $file.FullName
        if (-not $data) { continue }
        $hay = Normalize-Text (@($data.titulo, $data.resumo, ($data.palavras_chave -join " "), (($data.categorias.PSObject.Properties | ForEach-Object { $_.Value -join " " }) -join " "), (($data.categorias_rotulos.PSObject.Properties | ForEach-Object { $_.Value -join " " }) -join " ")) -join " ")
        $ok = $false
        foreach ($t in $terms) { if ($t -and $hay -match ("\b" + [regex]::Escape($t) + "\b")) { $ok = $true; break } }
        if ($ok) { $hits.Add($data) }
    }
}

if (-not $hits.Count) { Write-Output ("Nenhum livro encontrado para: " + $Query); exit 0 }
foreach ($hit in ($hits | Sort-Object titulo)) {
    Write-Output ("Titulo: " + $hit.titulo)
    foreach ($doc in $hit.arquivos_principais) { Write-Output $doc }
    Write-Output ""
}
