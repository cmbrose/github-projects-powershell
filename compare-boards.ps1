using module "./types/board.psm1"
using module "./types/item-content.psm1"

[CmdletBinding()]
param(
    [Board]$board1,
    [Board]$board2,
    [switch]$ignoreNonIssueNotes,
    [switch]$ignoreDone,
    [HashTable]$board1ToBoard2ColumnMap=@{}
)

$global:alreadyNotifiedItems = @()

function Search-ContentIdInBoard {
    param(
        [Board]$board,
        [string]$contentId
    )

    $board.columns | ForEach-Object {
        $col = $_

        $col.cards | ForEach-Object {
            $card = $_

            if ($card.content.id -eq $contentId) {
                return @($true, $col, $card)
            }
        }
    }

    return @($false, $null, $null)
}

function Search-NoteInBoard {
    param(
        [Board]$board,
        [string]$note
    )

    $board.columns | ForEach-Object {
        $col = $_

        $col.cards | ForEach-Object {
            $card = $_

            if ($card.note -eq $note) {
                return @($true, $col, $card)
            }
        }
    }

    return @($false, $null, $null)
}

function Compare-Boards {
    param(
        [Board]$b1,
        [Board]$b2,
        [string]$b1Name,
        [string]$b2Name,
        [HashTable]$columnMap
    )

    $b1.columns | ForEach-Object {
        $col1 = $_

        if ($ignoreDone -and $col1.name -eq "Done") {
            return
        }

        $targetColumn = $col1.name
        if ($columnMap[$col1.name]) {
            $targetColumn = $columnMap[$col1.name]
        }

        $col1.cards | ForEach-Object {
            $card1 = $_

            if ($card1.content.id) {
                $contentSpecifier = "$($card1.content.repository)#$($card1.content.number)"
                if ($global:alreadyNotifiedItems | Where-Object { $_ -eq $contentSpecifier }) {
                    return
                }

                $success, $col2, $card2 = Search-ContentIdInBoard -board $b2 -contentId $card1.content.id

                if (-not $success) {
                    $typePath = $content.type -eq "Issue" ? "issues" : "pulls"
                    $note = "https://github.com/$($card1.content.repository)/$typePath/$($card1.content.number)"

                    $success, $col2, $card2 = Search-NoteInBoard -board $b2 -note $note

                    if ($success) {
                        if ($targetColumn -ne $col2.name) {
                            Write-Warning "$b1Name has $contentSpecifier in '$($col1.name)', but $b2Name has it in '$($col2.name)'. Additionally in $b2Name it is a note."
                        } else {
                            Write-Warning "$b1Name has $contentSpecifier as a content card, but $b2Name has it as a note."
                        }
                    } else {
                        Write-Warning "$b1Name has $contentSpecifier, but $b2Name does not."
                    }

                    $global:alreadyNotifiedItems += $contentSpecifier
                } elseif ($targetColumn -ne $col2.name) {
                    Write-Warning "$b1Name has $contentSpecifier in '$($col1.name)', but $b2Name has it in '$($col2.name)'."
                    $global:alreadyNotifiedItems += $contentSpecifier
                }
            } else {
                $parseResult = $card1.note | Select-String -Pattern "^(https?://)github.com/([^/]+/[^/]+)/(issues|pulls)/(\d+)$"
                if (-not $parseResult.Matches.Success) {
                    if ($ignoreNonIssueNotes) {
                        return
                    }

                    $contentSpecifier = $card1.note
                } else {
                    $repo = $parseResult.Matches.Groups[2].Value
                    $type = $parseResult.Matches.Groups[3].Value
                    $number = $parseResult.Matches.Groups[4].Value
                    $contentSpecifier = "$repo#$number"
                }

                if ($global:alreadyNotifiedItems | Where-Object { $_ -eq $contentSpecifier }) {
                    return
                }

                $success, $col2, $card2 = Search-NoteInBoard -board $b2 -note $card1.note

                if (-not $success) {
                    Write-Warning "$b1Name has note $contentSpecifier, but $b2Name does not."
                    $global:alreadyNotifiedItems += $contentSpecifier
                } elseif ($targetColumn -ne $col2.name) {
                    Write-Warning "$b1Name has note $contentSpecifier in '$($col1.name)', but $b2Name has it in '$($col2.name)'."
                    $global:alreadyNotifiedItems += $contentSpecifier
                }
            }
        }
    }
}

Compare-Boards -b1 $board1 -b2 $board2 -b1Name "Board1" -b2Name "Board2" -columnMap $board1ToBoard2ColumnMap

$board2ToBoard1ColumnMap = @{}
$board1ToBoard2ColumnMap.keys | ForEach-Object {
    $board2ToBoard1ColumnMap[$board1ToBoard2ColumnMap[$_]] = $_
}

Compare-Boards -b1 $board2 -b2 $board1 -b1Name "Board2" -b2Name "Board1" -columnMap $board2ToBoard1ColumnMap