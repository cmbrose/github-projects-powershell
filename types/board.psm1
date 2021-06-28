using module "./graphql-object-base.psm1"
using module "./item-content.psm1"
using module "../common/client.psm1"
. (Join-Path $PSScriptRoot .. common constants.ps1)

class BoardQueryCursors {
    $ColumnCursor
    $CardCursor
}

class Board: GraphQLObjectBase {
    [BoardColumn[]]$Columns

    [string]$Org
    [string]$RepoName

    hidden [GraphQLClient]$Client

    Board(
        [string]$org,
        [string]$repoName,
        [string]$id,
        [GraphQLClient]$client
    ) {
        $this.org = $org
        $this.repoName = $repoName
        $this.id = $id
        $this.columns = @()

        $this.client = $client
    }

    # Constructor from value returned by $FetchSubQuery
    Board(
        [string]$org,
        [string]$repoName,
        $queryResult, 
        [GraphQLClient]$client
    ) {
        $this.org = $org
        $this.repoName = $repoName
        $this.client = $client
        $this.id = $queryResult.Id
        $this.columns = $queryResult.columns.edges.node | ForEach-Object {
            [BoardColumn]::new($_)
        }
    }

    hidden [void]MergeNextQueryPage($queryResult) {
        $queryResult.columns.edges.node | ForEach-Object {
            $nextColumn = [BoardColumn]::new($_)

            $existingColumn = $this.columns | Where-Object { $_.id -eq $nextColumn.id }

            if (-not $existingColumn) {
                $this.columns += $nextColumn
            } else {
                $nextColumn.cards | ForEach-Object { Add-CardToColumn -column $existingColumn -card $_ }
            }
        }
    }

    hidden static [string]FetchSubQuery([int]$pageSize, [string]$columnCursorVariableName, [string]$cardCursorVariableName) {
        return "
            id
            columns(first: 1, after: `$$columnCursorVariableName) {
                edges {
                    node {
                        $([BoardColumn]::FetchSubQuery($pageSize, $cardCursorVariableName))
                    }
                }
                pageInfo {
                    endCursor
                    hasNextPage
                }
            }
        "
    }

    hidden static [BoardQueryCursors]GetNextCursorsFromQueryResult($queryResult, [BoardQueryCursors]$prevCursors) {
        $columnPageInfo = $queryResult.columns.pageInfo
        $cardCursor = [BoardColumn]::GetNextCursorFromQueryResult($queryResult.columns.edges.node)

        $cursors = [BoardQueryCursors]::new()

        if ("" -ne $cardCursor) {
            $cursors.columnCursor = $prevCursors.columnCursor -eq "" ? $null : $prevCursors.columnCursor
            $cursors.cardCursor = $cardCursor
        } else {
            if (-not $columnPageInfo.hasNextPage) {
                return $null
            }

            $cursors.columnCursor = $columnPageInfo.endCursor
            $cursors.cardCursor = ""
        }

        return $cursors
    }

    [BoardColumn]GetColumn([string]$columnIdOrName) {
        return $this.columns 
        | Where-Object { ($_.name -eq $columnIdOrName) -or ($_.id -eq $columnIdOrName) } 
        | Select-Object -First 1
    }

    [BoardCard]AddNoteToColumn([string]$note, [string]$columnIdOrName) {
        return $this.AddNoteToColumn($note, $columnIdOrName, $false)
    }

    [BoardCard]AddNoteToColumn([string]$note, [string]$columnIdOrName, [bool]$moveIfExists) {
        $column = $this.GetColumn($columnIdOrName)
        if (-not $column) {
            throw "No column matched '$columnIdOrName'"
        }

        return Add-NoteToColumn -note $note -column $column -moveIfExists $moveIfExists -board $this
    }

    [BoardCard]AddContentToColumn([ItemContent]$content, [string]$columnIdOrName) {
        return $this.AddContentToColumn($content, $columnIdOrName, $false)
    }

    [BoardCard]AddContentToColumn([ItemContent]$content, [string]$columnIdOrName, [bool]$moveIfExists) {
        $column = $this.GetColumn($columnIdOrName)
        if (-not $column) {
            throw "No column matched '$columnIdOrName'"
        }

        $contentOrg, $contentRepo = $content.repository.split('/')
        if (($this.org -ne $contentOrg) -or (($this.repoName -ne "") -and ($this.repoName -ne $contentRepo))) {
            $typePath = $content.type -eq "Issue" ? "issues" : "pulls"
            $note = "https://github.com/$($content.repository)/$typePath/$($content.number)"
            return Add-NoteToColumn -note $note -column $column -moveIfExists $moveIfExists -board $this
        } else {
            return Add-ContentToColumn -content $content -column $column -moveIfExists $moveIfExists -board $this
        }
    }
}

class BoardColumn: GraphQLObjectBase {
    [string]$Name

    [BoardCard[]]$Cards

    BoardColumn([string]$id, [string]$name) {
        $this.id = $id
        $this.name = $name
        $this.cards = @()
    }

    # Constructor from value returned by $FetchSubQuery
    BoardColumn($queryResult) {
        $this.id = $queryResult.id
        $this.name = $queryResult.name
        $this.cards = $queryResult.cards.edges.node | ForEach-Object {
            [BoardCard]::new($_)
        }
    }

    static [string]FetchSubQuery([int]$pageSize, [string]$cursorVariableName) {
        return "
            id
            name
            cards(first: $pageSize, after: `$$cursorVariableName) {
                edges {
                    node {
                        $([BoardCard]::FetchSubQuery)
                    }
                }
                pageInfo {
                    endCursor
                    hasNextPage
                }
            }
        "
    }

    static [string]GetNextCursorFromQueryResult($queryResult) {
        $pageInfo = $queryResult.cards.pageInfo

        if (-not $pageInfo.hasNextPage) {
            return $null
        }

        return $pageInfo.endCursor
    }
}

function Add-NoteToColumn {
    [CmdletBinding()]
    [OutputType([BoardCard])]
    param(
        [string]$note,
        [BoardColumn]$column,
        [bool]$moveIfExists,
        [Board]$board
    )

    $columnWithNote = $board.columns | Where-Object { $_.cards | Where-Object { $_.note -eq $note } }

    if ($columnWithNote) {
        if (-not $moveIfExists) {
            throw "Note already exists in column '$($columnWithNote.name)'"
        }

        $existingCard = $columnWithNote.cards | Where-Object { $_.note -eq $note }

        if ($columnWithNote.id -eq $column.id) {
            Write-Verbose "Note is already on column '$($column.name)'"
            return $existingCard
        }
        
        $propName = "moveProjectCard"

        $query = "
            mutation {
                moveProjectCard(
                    input: {
                        cardId: `"$($existingCard.id)`",
                        columnId: `"$($column.id)`"
                    }
                ) {
                    cardEdge {
                        node {
                            $([BoardCard]::FetchSubQuery)
                        }
                    }
                }
            }
        "
    } else {
        $propName = "addProjectCard"

        $query = "
            mutation {
                addProjectCard(
                    input: {
                        projectColumnId: `"$($column.id)`", 
                        note: `"$note`"
                    }
                ) {
                    cardEdge {
                        node {
                            $([BoardCard]::FetchSubQuery)
                        }
                    }
                }
            }
        "
    }

    $result = $board.client.MakeRequest($query)

    $card = [BoardCard]::new($result.$propName.cardEdge.node)

    if ($columnWithNote) {
        Remove-CardFromColumn -column $columnWithNote -card $card
    }

    Add-CardToColumn -column $column -card $card

    $card
}

function Add-ContentToColumn {
    [CmdletBinding()]
    [OutputType([BoardCard])]
    param(
        [ItemContent]$content,
        [BoardColumn]$column,
        [bool]$moveIfExists,
        [Board]$board
    )

    $columnWithCard = $board.columns | Where-Object { $_.cards | Where-Object { $_.content.id -eq $content.id } }

    if ($columnWithCard) {
        if (-not $moveIfExists) {
            throw "Card for $($content.repository)#$($content.number) already exists in column '$($columnWithCard.name)'"
        }

        $existingCard = $columnWithCard.cards | Where-Object { $_.content.id -eq $content.id }

        if ($columnWithCard.id -eq $column.id) {
            Write-Verbose "Card for $($content.repository)#$($content.number) is already on column '$($column.name)'"
            return $existingCard
        }

        $propName = "moveProjectCard"

        $query = "
            mutation {
                moveProjectCard(
                    input: {
                        cardId: `"$($existingCard.id)`",
                        columnId: `"$($column.id)`"
                    }
                ) {
                    cardEdge {
                        node {
                            $([BoardCard]::FetchSubQuery)
                        }
                    }
                }
            }
        "
    } else {
        $propName = "addProjectCard"

        $query = "
            mutation {
                addProjectCard(
                    input: {
                        projectColumnId: `"$($column.id)`", 
                        contentId: `"$($content.id)`"
                    }
                ) {
                    cardEdge {
                        node {
                            $([BoardCard]::FetchSubQuery)
                        }
                    }
                }
            }
        "
    }

    $result = $board.client.MakeRequest($query)

    $card = [BoardCard]::new($result.$propName.cardEdge.node)

    if ($columnWithCard) {
        Remove-CardFromColumn -column $columnWithCard -card $card
    }

    Add-CardToColumn -column $column -card $card

    $card
}

function Add-CardToColumn {
    [CmdletBinding()]
    param(
        [BoardColumn]$column,
        [BoardCard]$card
    )

    Remove-CardFromColumn -column $column -card $card

    $column.cards += $card
}


function Remove-CardFromColumn {
    [CmdletBinding()]
    param(
        [BoardColumn]$column,
        [BoardCard]$card
    )

    $column.cards = $column.cards | Where-Object { $_.id -ne $card.id }
}


class BoardCard: GraphQLObjectBase {
    # The GraphQL Id of the Issue/PR this corresponds to
    [ItemContent]$Content

    # The note content - e.g. a url to an issue in a different repo/org
    [string]$Note

    # Constructor from value returned by $FetchSubQuery
    BoardCard(
        [string]$id,
        [string]$note,
        [ItemContent]$content
    ) {
        $this.id = $id
        $this.note = $note
        $this.content = $content
    }

    # Constructor from value returned by $FetchSubQuery
    BoardCard($queryResult) {
        $this.id = $queryResult.id
        $this.note = $queryResult.note
        $this.content = [ItemContent]::new($queryResult.content)
    }

    static [string]$FetchSubQuery = "
        id
        note
        content {
            $([ItemContent]::FetchSubQuery)
        }
    "
}

function Get-BoardInternal {
    [CmdletBinding()]
    [OutputType([Board])]
    param(
        [string]$query,
        [string]$rootObjectName,
        [string]$org,
        [string]$repoName = $null,
        [GraphQLClient]$client
    )

    $board = $null

    $variables = @{
        columnCursor = $null;
        cardCursor = ""
    }

    do {
        $result = $client.MakeRequest($query, $variables)

        $project = $result.$rootObjectName.project

        if (-not $board) {
            $board = [Board]::new($org, $repoName, $project, $client)
        } else {
            $board.MergeNextQueryPage($project)
        }

        $cursors = [Board]::GetNextCursorsFromQueryResult($project, $cursors)

        if ($cursors) {
            $variables.columnCursor = $cursors.columnCursor
            $variables.cardCursor = $cursors.cardCursor
        }
    } while ($null -ne $cursors)

    $board
}

function Get-RepoBoard {
    [CmdletBinding()]
    [OutputType([Board])]
    param(
        [string]$org,
        [string]$repoName,
        [int]$boardNumber,
        [Parameter(Mandatory = $true, ParameterSetName = "Client")]
        [GraphQLClient]$client,
        [Parameter(Mandatory = $true, ParameterSetName = "Token")]
        [string]$token
    )

    $pageSize = 100

    $query = "
        query (`$columnCursor: String, `$cardCursor: String) {
            repository(name: `"$repoName`", owner: `"$org`") {
                project(number: $boardNumber) {
                    $([Board]::FetchSubQuery($pageSize, "columnCursor", "cardCursor"))
                }
            }
        }
    "

    if (-not $client) {
        $client = New-GraphQLClient -Token $token
    }

    Get-BoardInternal -query $query -rootObjectName "repository" -org $org -repoName $repoName -client $client
}

function Get-OrganizationBoard {
    [CmdletBinding()]
    [OutputType([Board])]
    param(
        [string]$org,
        [int]$boardNumber,
        [Parameter(Mandatory = $true, ParameterSetName = "Client")]
        [GraphQLClient]$client,
        [Parameter(Mandatory = $true, ParameterSetName = "Token")]
        [string]$token
    )

    $pageSize = 100

    $query = "
        query (`$columnCursor: String, `$cardCursor: String) {
            organization(login: `"$org`") {
                project(number: $boardNumber) {
                    $([Board]::FetchSubQuery($pageSize, "columnCursor", "cardCursor"))
                }
            }
        }
    "

    if (-not $client) {
        $client = New-GraphQLClient -Token $token
    }

    Get-BoardInternal -query $query -rootObjectName "organization" -org $org -client $client
}

Export-ModuleMember -Function "Get-RepoBoard"
Export-ModuleMember -Function "Get-OrganizationBoard"