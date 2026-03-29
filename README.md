# Classificador de Livros

Sistema em PowerShell para classificar acervos de livros em pastas locais e permitir consultas por categoria diretamente no terminal.

## O que faz

- Gera um arquivo `classificador.md` em cada pasta de projeto detectada.
- Registra categorias úteis para busca futura.
- Lista livros por categoria, tema, público, uso e agora também por prefaciante.
- Funciona sobre múltiplas raízes de acervo.

## Instalação atual

Arquivos principais:

- `C:\Users\jairs\codex\classificador\classificador.ps1`
- `C:\Users\jairs\codex\classificador\classificador.cmd`
- `C:\Users\jairs\codex\classificador\config.json`

Wrapper global:

- `C:\Users\jairs\bin\classificador.cmd`

## Uso

Gerar classificadores faltantes:

```powershell
classificador
```

Reclassificar tudo:

```powershell
classificador --Refresh
```

Buscar por categoria:

```powershell
classificador casamento
classificador jovens
classificador escatologia
classificador tecnologia
```

Exemplos reais do acervo:

```powershell
classificador casamento
classificador "Eliel Batista"
classificador prefaciante
classificador escatologia
```

Buscar por prefácio:

```powershell
classificador prefaciante
classificador prefaciado
classificador "Eliel Batista"
```

Registrar nova raiz:

```powershell
classificador --RegisterRoot --Root "D:\Nova Pasta de Livros"
```

## Raízes configuradas

As raízes atuais ficam em `config.json`:

- `C:\Users\jairs\Documents\Meus Estudos Biblicos\Livros Teologia`
- `C:\Users\jairs\Documents\Meus Estudos Biblicos\Livro Tecnologia`
- `C:\Users\jairs\Documents\Meus Estudos Biblicos\Livros Contabilidade`
- `C:\Users\jairs\Documents\Meus Estudos Biblicos\Livros em Ingles`
- `C:\Users\jairs\Documents\Meus Estudos Biblicos\Livros Seculares`

## Como a classificação funciona

O sistema identifica pastas de projeto a partir de:

- presença de arquivos `.doc` ou `.docx`
- heurística para distinguir manuscrito principal de material auxiliar
- regras por nome de pasta e nome de arquivo
- overrides manuais para livros importantes

Ele grava em cada `classificador.md`:

- título
- pasta
- arquivos principais
- arquivos `.doc/.docx` mapeados
- categorias
- palavras-chave
- marcador `prefaciado`
- lista `prefaciantes`
- bloco JSON estruturado para leitura automática

## Ajustes manuais

Os ajustes finos ficam em `overrides.json`.

Use esse arquivo quando você quiser:

- corrigir resumo
- forçar categorias
- adicionar ou remover ênfase temática
- preservar exceções do acervo sem mexer no código

Estrutura:

```json
{
  "slug_da_pasta": {
    "resumo": "Resumo manual",
    "publico": ["casais", "lideres"],
    "tema": ["casamento"],
    "uso": ["aconselhamento"]
  }
}
```

O `slug_da_pasta` é derivado do nome da pasta do livro.

## Prefaciantes

Quando há arquivo de prefácio escrito por terceiro, o sistema tenta extrair o nome do prefaciante a partir do nome do arquivo, por exemplo:

- `Apresentacao do Livro por pastor Eliel Batista.docx`
- `JOABE - PREFACIO COUTO.docx`

Limite atual:

- a detecção de prefaciantes usa principalmente o nome do arquivo
- não faz interpretação profunda do conteúdo interno do prefácio
- prefácios genéricos como `Prefácio.docx` podem exigir refinamento futuro

## Publicação no GitHub

Esta pasta pode ser publicada como projeto independente. Fluxo sugerido:

```powershell
cd C:\Users\jairs\codex\classificador
git init
git add .
git commit -m "Inicializa classificador de livros"
gh repo create classificador --public --source . --remote origin --push
```

Se o `gh` não estiver autenticado, primeiro:

```powershell
gh auth login
```

## Observações

- O comando `classificador` já funciona no terminal atual.
- Se uma nova sessão de terminal não reconhecer o comando, basta abrir um novo terminal.
- A licença do projeto é `MIT`.
