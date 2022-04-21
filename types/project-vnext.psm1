using module "./graphql-object-base.psm1"
using module "./item-content.psm1"
using module "../common/client.psm1"
. (Join-Path $PSScriptRoot .. common constants.ps1)

class Project: GraphQLObjectBase {
    [ProjectField[]]$Fields

    [ProjectItem[]]$Items

    [string]$Title

    [int]$Number

    hidden [GraphQLClient]$client

    Project(
        [string]$id,
        [string]$title,
        [int]$number,
        [ProjectField[]]$fields,
        [ProjectItem[]]$items,
        [GraphQLClient]$client
    ) {
        $this.id = $id
        $this.title = $title
        $this.number = $number
        $this.fields = $fields | ForEach-Object { $_ }
        $this.items = (($items) ? ($items | ForEach-Object { $_.SetParent($this); $_ }) : @())
        $this.client = $client
    }

    [ProjectField]GetField(
        [string]$fieldNameOrId
    ) {
        return $this.fields 
        | Where-Object { ($_.name -eq $fieldNameOrId) -or ($_.id -eq $fieldNameOrId) }
        | Select-Object -First 1
    }

    [void]RemoveItem(
        [ProjectItem]$item
    ) {
        $query = "
            mutation {
                deleteProjectNextItem(
                    input: {
                        projectId: `"$($this.id)`",
                        itemId: `"$($item.id)`"
                    }
                ) {
                    deletedItemId
                }
            }
        "

        try {
            $result = $this.client.MakeRequest($query)
        } catch [Exception] {
            Write-Error "Failed to delete item '$($item.id)' from project"
            throw $_
        }

        $this.items = $this.items | Where-Object { $_.id -ne $item.id }
    }

    [ProjectItem]AddItemByContentId(
        [string]$contentId
    ) {
        $query = "
            mutation {
                addProjectNextItem(
                    input: {
                        projectId: `"$($this.id)`", 
                        contentId: `"$($contentId)`"
                    }
                ) {
                    projectNextItem {
                        $([ProjectItem]::FetchSubQuery)
                    }
                }
            }
        "

        try {
            $result = $this.client.MakeRequest($query)
        } catch [Exception] {
            Write-Error "Failed to add content '$contentId' to project"
            throw $_
        }

        $item = [ProjectItem]::new($result.addProjectNextItem.projectNextItem, $this.client)

        # If the item already exists in the board the API just returns the same item with the same id
        # In this case, remove the item that already exists
        $this.items = $this.items | Where-Object { $_.id -ne $item.id }

        $item.SetParent($this)
        $this.items += $item

        return $item
    }
}

class ProjectItem: GraphQLObjectBase {
    # The Issue/PR this corresponds to
    [ItemContent]$Content

    [ProjectFieldValue[]]$FieldValues

    hidden [Project]$Parent

    hidden [GraphQLClient]$Client

    ProjectItem(
        [string]$id,
        [ItemContent]$content,
        [ProjectFieldValue[]]$fieldValues
    ) {
        $this.id = $id
        $this.content = $content
        $this.fieldValues = $fieldValues
        $this.client = $null
    }

    # Constructor from value returned by $FetchSubQuery
    ProjectItem(
        $queryResult,
        [GraphQLClient]$client
    ) {
        $this.id = $queryResult.id
        $this.content = [ItemContent]::new($queryResult.content, $client)

        $this.fieldValues = $queryResult.fieldValues.edges.node | ForEach-Object {
            $fieldId = $_.projectField.id

            [ProjectFieldValue]::new($fieldId, $_.value)
        }

        $this.client = $client
    }

    [void]SetParent(
        [Project]$parent
    ) {
        $this.parent = $parent
    }

    [bool]HasValueForField(
        [string]$fieldNameOrId
    ) {
        $value = $this.GetFieldValue($fieldNameOrId)

        return "" -ne $value
    }

    [string]GetFieldValue(
        [string]$fieldNameOrId
    ) {
        $field = $this.parent.GetField($fieldNameOrId)
        if (-not $field) {
            return $null
        }

        $value = $this.fieldValues | Where-Object { $_.fieldId -eq $field.id }

        if (-not $value) {
            return $null
        }

        if ($field.options) {
            $option = $field.GetFieldOption($value.value)
            if (-not $option) {
                return $null
            } else {
                return $option.name
            }
        } else {
            return $value.value
        }
    }

    [bool]TrySetFieldValue(
        [string]$fieldNameOrId,
        [string]$value # NameOrId if option
    ) {
        return $this.TrySetFieldValue($fieldNameOrId, $value, $false)
    }

    [bool]TrySetFieldValue(
        [string]$fieldNameOrId,
        [string]$value, # NameOrId if option,
        [bool]$enableOptionLikeMatching
    ) {
        $field = $this.parent.GetField($fieldNameOrId)
        if (-not $field) {
            return $false
        }

        if (-not $value) {
            $targetValue = ""
        } elseif ($field.options) {
            $option = $field.GetFieldOption($value, $enableOptionLikeMatching)
            if (-not $option) {
                return $false
            }

            $targetValue = $option.id
        } else {
            $targetValue = $value
        }

        $query = "
            mutation (`$value: String!) {
                updateProjectNextItemField(
                    input: {
                        projectId: `"$($this.parent.id)`"
                        itemId: `"$($this.id)`"
                        fieldId: `"$($field.id)`"
                        value: `$value
                    }
                ) {
                    projectNextItem {
                        id
                    }
                }
            }
        "

        $variables = @{
            value = $targetValue;
        }

        try {
            $_ = $this.client.MakeRequest($query, $variables)
        } catch [Exception] {
            Write-Error "Failed to set field value for item $($this.id)"
            throw $_
        }

        if ($this.HasValueForField($fieldNameOrId)) {
            $this.fieldValues | Where-Object { $_.fieldId -eq $field.id } | ForEach-Object { $_.value = $targetValue } 
        } else {
            $this.fieldValues += [ProjectFieldValue]::new($field.id, $targetValue)
        }

        return $true
    }

    static [string]$FetchSubQuery = "
        id
        fieldValues(first: $global:maxSupportedProjectFields) {
            edges {
                node {
                    projectField {
                        id
                    }
                    value
                }
            }
        }
        content {
            $([ItemContent]::FetchSubQuery)
        }
    "
}

class ProjectField: GraphQLObjectBase {
    [string]$Name

    [ProjectFieldOption[]]$Options

    ProjectField(
        [string]$id,
        [string]$name,
        [ProjectFieldOption[]]$options=$null
    ) {
        $this.id = $id
        $this.name = $name
        $this.options = $options
    }

    # Constructor from value returned by $FetchSubQuery
    ProjectField($queryResult) {
        $this.id = $queryResult.id
        $this.name = $queryResult.name

        if ($queryResult.settings) {
            $settings = $_.settings | ConvertFrom-Json

            if ($settings.options) {
                $this.options = $settings.options | ForEach-Object {
                    [ProjectFieldOption]::new($_.id, $_.name)
                }
            }
        }
    }

    [ProjectFieldOption]GetFieldOption(
        [string]$optionNameOrId
    ) {
        return $this.GetFieldOption($optionNameOrId, $false)
    }

    [ProjectFieldOption]GetFieldOption(
        [string]$optionNameOrId,
        [bool]$enableNameLikeMatching
    ) {
        if (-not $this.options) {
            return $null
        }

        return $this.options 
        | Where-Object { 
            ($_.name -eq $optionNameOrId) -or
            ($enableNameLikeMatching -and ($_.name -like "*$optionNameOrId*")) -or
            ($_.id -eq $optionNameOrId)
        } | Select-Object -First 1
    }

    static [string]$FetchSubQuery = "
        id
        name
        settings
    "
}

class ProjectFieldOption: GraphQLObjectBase {
    [string]$Name

    ProjectFieldOption(
        [string]$id,
        [string]$name
    ) {
        $this.id = $id
        $this.name = $name
    }
}

class ProjectFieldValue {
    [string]$FieldId

    [string]$Value

    ProjectFieldValue(
        [string]$fieldId,
        [string]$value
    ) {
        $this.fieldId = $fieldId
        $this.value = $value
    }
}

function Get-ProjectItems {
    [CmdletBinding()]
    [OutputType([ProjectItem[]])]
    param(
        [string]$org,
        [int]$projectNumber,
        [GraphQLClient]$client
    )

    $pageSize = 100

    $query = "
        query (`$id: Int!, `$org: String!, `$cursor: String) {
            organization(login: `$org) {
                projectNext(number: `$id) {
                    items(first: $pageSize, after: `$cursor) {                
                        edges {
                            node {
                                id
                            }
                        }
                        pageInfo {
                            endCursor
                            hasNextPage
                        }
                    }
                }
            }
        }
    "

    $variables = @{
        id = $projectNumber;
        org = $org;
        cursor = $null;
    }

    do {        
        $result = $client.MakeRequest($query, $variables)

        $itemIds = $result.organization.projectNext.items.edges.node.id

        Get-ProjectItemsByIdBatch -ids $itemIds -client $client

        $pageInfo = $result.organization.projectNext.items.pageInfo

        $variables.cursor = $pageInfo.endCursor
    } while ($pageInfo.hasNextPage)
}

# For performance, we load ProjectNextItems in batches. This causes issues with authorization
# if the current token is allowed to access some issues, but not others - this can easily happen
# if the project has items from multiple orgs. In that case we filter out the forbidden items
# and just ignore them.
function Get-ProjectItemsByIdBatch {
    [CmdletBinding()]
    [OutputType([ProjectField[]])]
    param(
        [string[]]$ids,
        [GraphQLClient]$client
    )

    # Hashtable is important here because @{} is case-insensitive
    # These are just inverse maps of each other
    $idToNodeNameMap = New-Object system.collections.hashtable
    $nodeNameToIdMap = New-Object system.collections.hashtable
    foreach ($id in $ids) {
        $idx = $ids.IndexOf($id)
        $idToNodeNameMap[$id] = "n$idx"
        $nodeNameToIdMap["n$idx"] = $id
    }

    function Get-BatchQuery {
        param([string[]]$ids)

        $subQueries = $ids | ForEach-Object {
            # The subquery looks like `n0: node(id: "12345") { ... }`
            "$($idToNodeNameMap[$_]): node(id: `"$_`") {
                ... on ProjectNextItem {
                    $([ProjectItem]::FetchSubQuery)
                }
            }"
        }
    
        "query {
            $($subQueries -join "`n")
        }"
    }

    $query = Get-BatchQuery -ids $ids

    try {
        $result = $client.MakeRequest($query)
    } catch {
        $exception = $_.Exception
    }

    if ($exception) {
        # On exception, find errors due to auth and remove those items.
        # Note, if there are other errors the second query will fail
        # with the same error and we will throw that one.

        # The exception message is json like:
        # [
        #     {
        #         "type": "FORBIDDEN",
        #         "path": [
        #             "bad-node-name",
        #             "content"
        #         ],
        #         ...
        #     },
        # ]
        $badNodes = $exception.Message 
        | ConvertFrom-Json 
        | Where-Object { $_.type -eq "FORBIDDEN" }
        | ForEach-Object { $_.path[0] } # Index 0 is the node name
        | ForEach-Object { $nodeNameToIdMap[$_] }

        Write-Warning "Could not load node ids $($badNodes -join ", ")"

        $ids = $ids | Where-Object { $badNodes -notcontains $_ }

        $query = Get-BatchQuery -ids $ids

        $result = $client.MakeRequest($query)
    }

    $ids 
    | ForEach-Object { 
        $item = $result.($idToNodeNameMap[$_])        
        [ProjectItem]::new($item, $client)
    }
    | Where-Object { $_.content.type -ne "DraftIssue" }
}

function Get-ProjectFields {
    [CmdletBinding()]
    [OutputType([ProjectField[]])]
    param(
        [string]$org,
        [int]$projectNumber,
        [GraphQLClient]$client
    )

    $query = "
        query (`$id: Int!, `$org: String!) {
            organization(login: `$org) {
                projectNext(number: `$id) {
                    fields(first: $global:maxSupportedProjectFields) {
                        edges {
                            node {
                                $([ProjectField]::FetchSubQuery)
                            }
                        }
                        pageInfo {
                            hasNextPage
                        }
                    }
                }
            }
        }
    "

    $variables = @{
        id = $projectNumber;
        org = $org;
    }

    $result = $client.MakeRequest($query, $variables)

    if ($result.organization.projectNext.fields.pageInfo.hasNextPage) {
        throw "Could not fetch fields for Project #$projectNumber - it has more than the supported limit of $global:maxSupportedProjectFields fields"
    }

    $result.organization.projectNext.fields.edges.node 
    | ForEach-Object { [ProjectField]::new($_) }
    | Where-Object { -not (Is-IgnoredField $_) }
}

function Is-IgnoredField {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [ProjectField]$field
    )

    # These are all set on the content itself and not returned by GraphQL for fieldValues
    ($field.name -eq "Title") -or
    ($field.name -eq "Assignees") -or
    ($field.name -eq "Labels") -or
    ($field.name -eq "Repository") -or
    ($field.name -eq "Milestone") -or
    ($field.name -eq "Linked Pull Requests") -or
    ($field.name -eq "Reviewers") -or
    ($field.name -eq "Tracks")
}

function Get-Project {
    [CmdletBinding()]
    [OutputType([Project])]
    param(
        [string]$org,
        [int]$projectNumber,
        [Parameter(Mandatory = $true, ParameterSetName = "Client")]
        [GraphQLClient]$client,
        [Parameter(Mandatory = $true, ParameterSetName = "Token")]
        [string]$token
    )

    #TODO - this could be added into another query
    $query = "
        query (`$id: Int!, `$org: String!) {
            organization(login: `$org) {
                projectNext(number: `$id) {
                    id
                    title
                    number
                }
            }
        }
    "

    $variables = @{
        id = $projectNumber;
        org = $org;
    }

    if (-not $client) {
        $client = New-GraphQLClient -Token $token
    }

    $result = $client.MakeRequest($query, $variables)

    $project = [Project]::new(
        $result.organization.projectNext.id,
        $result.organization.projectNext.title,
        $result.organization.projectNext.number,
        (Get-ProjectFields -org $org -projectNumber $projectNumber -Client $client),
        (Get-ProjectItems -org $org -projectNumber $projectNumber -Client $client),
        $client
    )

    $project
}


function Get-AllProjectNumbers {
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [string]$org,
        [Parameter(Mandatory = $true, ParameterSetName = "Client")]
        [GraphQLClient]$client,
        [Parameter(Mandatory = $true, ParameterSetName = "Token")]
        [string]$token
    )

    $query = "
        query (`$org: String!, `$cursor: String) {
            organization(login: `$org) {
                projectsNext(first: 100, after: `$cursor) {
                    edges {
                        node { 
                            number 
                            closed
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
        org = $org;
    }

    if (-not $client) {
        $client = New-GraphQLClient -Token $token
    }

    $projectNumbers = @()
    
    do {
        $result = $client.MakeRequest($query, $variables)
        $projects = $result.organization.projectsNext
        
        $projectNumbers += $projects.edges.node | Where-Object { -not $_.closed } | ForEach-Object { $_.number }
        
        $variables.cursor = $projects.pageInfo.endCursor            
    } while ($projects.pageInfo.hasNextPage)

    $projectNumbers
}

Export-ModuleMember -Function "Get-Project"
Export-ModuleMember -Function "Get-AllProjectNumbers"
