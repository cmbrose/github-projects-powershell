using module "./graphql-object-base.psm1"
using module "./label.psm1"
using module "../common/client.psm1"

class Repository: GraphQLObjectBase {
    [String]$Name

    [Label[]]$Labels

    hidden [GraphQLClient]$Client

    # Constructor from value returned by $FetchSubQuery
    Repository(
        $queryResult,
        [GraphQLClient]$client
    ) {
        $this.id = $queryResult.id
        $this.name = $queryResult.name
        $this.client = $client
    }

    hidden [void]SetLabels([Label[]]$labels) {
        $this.labels = $labels
    }

    [Label]AddLabel(
        [string]$name,
        [string]$color
    ) {
        $query = "
            mutation {
                createLabel(input: {
                    repositoryId: `"$($this.id)`",
                    name: `"$name`",
                    color: `"$color`"
                }) {
                    label {
                        $([Label]::FetchSubQuery)
                    }
                }
            }
        "
    
        $result = $this.client.MakeRequest($query)
    
        $label = [Label]::new($result.createLabel.label)

        $this.labels += $label

        return $label
    }

    [void]DeleteLabel(
        [string]$labelNameOrId
    ) {
        $id = $this.Labels | Where-Object { $_.name -eq $labelNameOrId } | ForEach-Object { $_.id }
        if (-not $id) {
            $id = $labelNameOrId # Maybe we're just out of sync and the user knows more than us
        }

        $query = "
            mutation {
                deleteLabel(input: {
                    id: `"$id`"
                }) {
                    clientMutationId # We don't use this, but need *some* property here for the query to work
                }
            }
        "

        $this.client.MakeRequest($query)

        $this.labels = $this.labels | Where-Object { $_.id -ne $id }
    }

    static [string]$FetchSubQuery = "
        id
        name        
    "
}

function Get-RepositoryLabels {
    [CmdletBinding()]
    [OutputType([Label[]])]
    param(
        [string]$org,
        [string]$name,
        [GraphQLClient]$client
    )

    $query = "
        query (`$cursor: String) {
            repository(name: `"$name`", owner: `"$org`") {
                labels(first: 100, after: `$cursor) {
                    edges {
                        node {
                            $([Label]::FetchSubQuery)
                        }
                    }
                    pageInfo {
                        endCursor
                        hasNextPage
                    }
                }
            }
        }
    "
    
    $variables = @{
        cursor = $null;
    }

    $labels = @()

    do {
        $result = $client.MakeRequest($query, $variables)

        $labels += $result.repository.labels.edges.node | ForEach-Object { [Label]::new($_) }

        $variables.cursor = $result.pageInfo.endCursor
    } while ($result.pageInfo.hasNextPage)

    $labels
}

function Get-Repository {
    [CmdletBinding()]
    [OutputType([Repository])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$org,
        [Parameter(Mandatory = $true)]
        [string]$name,
        [Parameter(Mandatory = $true, ParameterSetName = "Client")]
        [GraphQLClient]$client,
        [Parameter(Mandatory = $true, ParameterSetName = "Token")]
        [string]$token
    )

    $query = "
        query {
            repository(name: `"$name`", owner: `"$org`") {
                $([Repository]::FetchSubQuery)
            }
        }
    "

    if (-not $client) {
        $client = New-GraphQLClient -Token $token
    }

    $result = $client.MakeRequest($query)

    $repo = [Repository]::new($result.repository, $client)

    $labels = Get-RepositoryLabels -org $org -name $name -client $client

    $repo.SetLabels($labels)

    $repo
}

Export-ModuleMember -Function "Get-Repository"