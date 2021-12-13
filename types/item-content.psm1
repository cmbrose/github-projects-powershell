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

    [string]$Body

    [bool]$Closed

    [Label[]]$Labels

    [Comment[]]$Comments = $null

    hidden [GraphQLClient]$Client

    ItemContent(
        [string]$id,
        [int]$number,
        [string]$repository,
        [string]$type,
        [string]$body,
        [bool]$closed,
        [Label[]]$labels,
        [Comment[]]$comments
    ) {
        $this.id = $id
        $this.number = $number
        $this.repository = $repository
        $this.type = $type
        $this.body = $body
        $this.closed = $closed
        $this.labels = $labels
        $this.comments = $comments

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
        $this.body = $queryResult.body
        $this.closed = $queryResult.closed

        if ($queryResult.labels.edges.node) {
            $this.labels = $queryResult.labels.edges.node | ForEach-Object { [Label]::new($_) }
        } else {
            $this.labels = @()
        }

        $this.client = $client
        $this.comments = $null # Call FetchComments() to populate
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

    [void]FetchComments() {
        $pageSize = 100

        $commentSubquery = "
            comments(first: $pageSize, after: `$cursor) {
                edges {
                    node {
                        $([Comment]::FetchSubQuery)
                    }
                }
                pageInfo {
                    endCursor
                    hasNextPage
                }
            }
        "

        $query = "
            query (`$id: Int!, `$org: String!, `$repositoryName: String!, `$cursor: String) {
                repository(name: `$repositoryName, owner: `$org) {
                    issueOrPullRequest(number: `$id) {
                        ... on Issue {
                            $commentSubquery
                        }
                        ... on PullRequest {
                            $commentSubquery
                        }
                    }
                }
            }
        "

        $org, $repositoryName = $this.Repository.Split('/')

        $variables = @{
            repositoryName = $repositoryName;
            org = $org;
            id = $this.Number
        }

        $this.Comments = @()

        $pageInfo = $null

        do {        
            $result = $this.Client.MakeRequest($query, $variables)

            $commentsResult = $result.repository.issueOrPullRequest.comments

            if (-not $commentsResult.edges.node) {
                break
            }

            $this.Comments += $commentsResult.edges.node | ForEach-Object {
                [Comment]::new($_, $this.Client, $this)
            }

            $pageInfo = $commentsResult.pageInfo

            $variables.cursor = $pageInfo.endCursor
        } while ($pageInfo.hasNextPage)
    }

    [void]UpdateBody([string]$newBody) {
        $newBody = $newBody.Replace("`"", "\`"")

        if ($this.type -eq "Issue") {
            $query = "
                mutation (`$id: String!, `$body: String!) {
                    updateIssue(
                        input: {
                            id: `$id,
                            body: `$body
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
                mutation (`$id: String!, `$body: String!) {
                    updateIssue(
                        input: {
                            pullRequestId: `$id,
                            body: `$body
                        }
                    ) {
                        pullRequest {
                            id
                        }
                    }
                }
            "
        }

        $variables = @{
            id = $this.Id;
            body = $newBody;
        }

        $this.client.MakeRequest($query, $variables)

        $this.Body = $newBody
    }

    [Comment]AddComment([string]$bodyText) {
        $bodyText = $bodyText.Replace("`"", "\`"")

        $query = "
            mutation (`$id: String!, `$body: String!) {
                addComment(input: {
                    subjectId: `$id,
                    body: `$body
                }) {
                    commentEdge {
                        node {
                            $([Comment]::FetchSubQuery)
                        }
                    }
                }
            }
        "

        $variables = @{
            id = $this.Id;
            body = $bodyText;
        }

        $result = $this.client.MakeRequest($query, $variables)

        $comment = [Comment]::new($result.addComment.commentEdge.node, $this.client, $this)

        # Comments haven't been fetched, user should call FetchComments
        if ($this.Comments) {
            $this.Comments += $comment
        }

        return $comment
    }

    # Note: this must come before FetchSubQuery or it will be evaluated as an empty string
    static [string]$CommonQueryProperties = "
        id
        number
        closed
        body
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

class Comment: GraphQLObjectBase {
    hidden [ItemContent]$Parent

    [string]$Body
    [string]$Author
    [string]$CreatedAt

    [GraphQLClient]$Client

    # Constructor from value returned by $FetchSubQuery
    Comment(
        $queryResult,
        [GraphQLClient]$client,
        [ItemContent]$parent
    ) {
        $this.id = $queryResult.id
        $this.body = $queryResult.body
        $this.author = $queryResult.author.login
        $this.createdAt = $queryResult.createdAt
        $this.client = $client
        $this.parent = $parent
    }

    [void]UpdateBody([string]$newBody) {
        $newBody = $newBody.Replace("`"", "\`"")

        if ($this.Parent.Type -eq "Issue") {
            $query = "
                mutation (`$id: String!, `$body: String!) {
                    updateIssueComment(input: {
                        id: `$id,
                        body: `$body
                    }) {
                        issueComment { id }
                    }
                }
            "
        } else {
            $query = "
                mutation (`$id: String!, `$body: String!) {
                    updatePullRequestReviewComment(input: {
                        pullRequestReviewCommentId: `$id,
                        body: `$body
                    }) {
                        pullRequestReviewComment { id }
                    }
                }
            "
        }

         $variables = @{
            id = $this.Id;
            body = $newBody;
        }

        $this.client.MakeRequest($query, $variables)

        $this.Body = $newBody
    }

    static [string]$FetchSubQuery = "
        id
        body
        author {
            login
        }
        createdAt
    "
}

function Get-ItemContent {
    [CmdletBinding()]
    [OutputType([ItemContent])]
    param(
        [string]$org,
        [string]$repositoryName,
        [int]$number,
        [switch]$fetchComments,
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

    $itemContent = [ItemContent]::new($result.repository.issueOrPullRequest, $client)

    if ($fetchComments) {
        $itemContent.FetchComments()
    }

    $itemContent
}

Export-ModuleMember -Function "Get-ItemContent"