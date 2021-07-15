using module "./graphql-object-base.psm1"
using module "./label.psm1"
using module "../common/client.psm1"

# This represents either an Issue or a PR. The schemas technically are different, but the intersection is enough for our use.
class ItemContent: GraphQLObjectBase {
    # The Id number of the item. Note this is NOT the same as Id
    [int]$Number

    # The repository the item belongs to in the form <organization>/<repository>
    [string]$Repository

    # "Issue" or "PullRequest"
    [string]$Type

    [bool]$Closed

    [Label[]]$Labels

    hidden [GraphQLClient]$Client

    ItemContent(
        [string]$id,
        [int]$number,
        [string]$repository,
        [string]$type,
        [bool]$closed,
        [Label[]]$labels
    ) {
        $this.id = $id
        $this.number = $number
        $this.repository = $repository
        $this.type = $type
        $this.closed = $closed
        $this.labels = $labels

        if ($this.type -eq "pulls") {
            $this.type = "PullRequest"
        }
    }

    # Constructor from value returned by $FetchSubQuery
    ItemContent(
        $queryResult,
        [GraphQLClient]$client
    ) {
        $this.id = $queryResult.id
        $this.number = $queryResult.number
        $this.repository = $queryResult.repository.nameWithOwner
        $this.type = $queryResult.__typename
        $this.closed = $queryResult.closed
        $this.labels = $queryResult.labels.edges.node | ForEach-Object { [Label]::new($_) }
        $this.client = $client
    }

    [void]Close() {
        if ($this.type -eq "Issue") {
            $query = "
                mutation {
                    closeIssue(
                        input: {
                            issueId: `"$($this.id)`"
                        }
                    ) {
                        issue {
                            id
                        }
                    }
              }
            "
        } else {
            $query = "
                mutation {
                    closePullRequest(
                        input: {
                            pullRequestId: `"$($this.id)`"
                        }
                    ) {
                        pullRequest {
                            id
                        }
                    }
              }
            "
        }

        $this.client.MakeRequest($query)
    }

    [void]AddLabel([Label]$label) {
        $query = "
            mutation {    
                addLabelsToLabelable(
                    input: {
                        labelableId: `"$($this.id)`",
                        labelIds: `"$($label.id)`"
                    }
                ) {
                    labelable {
                        $([ItemContent]::FetchSubQuery)
                    }
                }
            }
        "

        $result = $this.client.MakeRequest($query)

        $this.labels = $result.addLabelsToLabelable.labelable.labels.edges.node | ForEach-Object { [Label]::new($_) }
    }

    [void]RemoveLabel([Label]$label) {
        $query = "
            mutation {    
                removeLabelsFromLabelable(
                    input: {
                        labelableId: `"$($this.id)`",
                        labelIds: `"$($label.id)`"
                    }
                ) {
                    labelable {
                        $([ItemContent]::FetchSubQuery)
                    }
                }
            }
        "

        $result = $this.client.MakeRequest($query)

        $this.labels = $result.removeLabelsFromLabelable.labelable.labels.edges.node | ForEach-Object { [Label]::new($_) }
    }

    # Note: this must come before FetchSubQuery it will be evaluated as an empty string
    static [string]$CommonQueryProperties = "
        id
        number
        closed
        repository {
            nameWithOwner
        }
        labels(first: 100) {
            edges {
                node {
                    $([Label]::FetchSubQuery)
                }
            }
        }
    "

    static [string]$FetchSubQuery = "
        __typename
        ... on Issue {
            $([ItemContent]::CommonQueryProperties)
        }
        ... on PullRequest {
            $([ItemContent]::CommonQueryProperties)
        }
    "
}

function Get-ItemContent {
    [CmdletBinding()]
    [OutputType([ItemContent])]
    param(
        [string]$org,
        [string]$repositoryName,
        [int]$number,
        [Parameter(Mandatory = $true, ParameterSetName = "Client")]
        [GraphQLClient]$client,
        [Parameter(Mandatory = $true, ParameterSetName = "Token")]
        [string]$token
    )

    $query = "
        query (`$id: Int!, `$org: String!, `$repositoryName: String!) {
            repository(name: `$repositoryName, owner: `$org) {
                issueOrPullRequest(number: `$id) {
                    $([ItemContent]::FetchSubQuery)
                }
            }
        }
    "

    $variables = @{
        repositoryName = $repositoryName;
        org = $org;
        id = $number
    }

    if (-not $client) {
        $client = New-GraphQLClient -Token $token
    }

    $result = $client.MakeRequest($query, $variables)

    [ItemContent]::new($result.repository.issueOrPullRequest, $client)
}

Export-ModuleMember -Function "Get-ItemContent"