using module "./graphql-object-base.psm1"
using module "../common/client.psm1"

# This represents either an Issue or a PR. The schemas technically are different, but the intersection is enough for our use.
class ItemContent: GraphQLObjectBase {
    # The Id number of the item. Note this is NOT the same as Id
    [int]$Number

    # The repository the item belongs to in the form <organization>/<repository>
    [String]$Repository

    # "Issue" or "PullRequest"
    [String]$Type

    ItemContent(
        [string]$id,
        [int]$number,
        [string]$repository,
        [string]$type
    ) {
        $this.id = $id
        $this.number = $number
        $this.repository = $repository
        $this.type = $type

        if ($this.type -eq "pulls") {
            $this.type = "PullRequest"
        }
    }

    # Constructor from value returned by $FetchSubQuery
    ItemContent($queryResult) {
        $this.id = $queryResult.id
        $this.number = $queryResult.number
        $this.repository = $queryResult.repository.nameWithOwner
        $this.type = $queryResult.__typename
    }

    static [string]$FetchSubQuery = "
        __typename
        ... on Issue {
            id
            number
            repository {
                nameWithOwner
            }
        }
        ... on PullRequest {
            id
            number
            repository {
                nameWithOwner
            }
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

    [ItemContent]::new($result.repository.issueOrPullRequest)
}

Export-ModuleMember -Function "Get-ItemContent"