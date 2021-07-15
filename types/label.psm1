using module "./graphql-object-base.psm1"
using module "../common/client.psm1"

class Label: GraphQLObjectBase {
    [String]$Name

    [String]$Color

    # Constructor from value returned by $FetchSubQuery
    Label($queryResult) {
        $this.id = $queryResult.id
        $this.name = $queryResult.name
        $this.color = $queryResult.color
    }

    static [string]$FetchSubQuery = "
        id
        name
        color
    "
}

function Add-NewLabelToRepo {
    [CmdletBinding()]
    [OutputType([Label])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$repoId,
        [Parameter(Mandatory = $true)]
        [string]$name,
        [Parameter(Mandatory = $true)]
        [string]$color,
        [Parameter(Mandatory = $true, ParameterSetName = "Client")]
        [GraphQLClient]$client,
        [Parameter(Mandatory = $true, ParameterSetName = "Token")]
        [string]$token
    )

    $query = "
        mutation {
            createLabel(input: {
                repositoryId: `"$repoId`",
                name: `"$name`",
                color: `"$color`"
            }) {
                label {
                    $([Label]::FetchSubQuery)
                }
            }
        }
    "

    if (-not $client) {
        $client = New-GraphQLClient -Token $token
    }

    $result = $client.MakeRequest($query)

    [Label]::new($result.createLabel.label)
}

function Remove-LabelFromRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$labelId,
        [Parameter(Mandatory = $true, ParameterSetName = "Client")]
        [GraphQLClient]$client,
        [Parameter(Mandatory = $true, ParameterSetName = "Token")]
        [string]$token
    )

    $query = "
        mutation {
            deleteLabel(input: {
                id: `"$labelId`"
            }) {
                clientMutationId # We don't use this, but need *some* property here for the query to work
            }
        }
    "

    if (-not $client) {
        $client = New-GraphQLClient -Token $token
    }

    $_ = $client.MakeRequest($query)
}

Export-ModuleMember -Function "Add-NewLabelToRepo"