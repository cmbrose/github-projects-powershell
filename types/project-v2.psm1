using module "./graphql-object-base.psm1"
using module "./item-content.psm1"
using module "../common/client.psm1"
. (Join-Path $PSScriptRoot .. common constants.ps1)

class ProjectV2: GraphQLObjectBase {
    [ProjectV2Field[]]$Fields

    [ProjectV2Item[]]$Items

    [string]$Title

    [int]$Number

    hidden [GraphQLClient]$client

    ProjectV2(
        [string]$id,
        [string]$title,
        [int]$number,
        [ProjectV2Field[]]$fields,
        [ProjectV2Item[]]$items,
        [GraphQLClient]$client
    ) {
        $this.id = $id
        $this.title = $title
        $this.number = $number
        $this.fields = $fields | ForEach-Object { $_ }
        $this.items = (($items) ? ($items | ForEach-Object { $_.SetParent($this); $_ }) : @())
        $this.client = $client
    }

    [ProjectV2Field]GetField(
        [string]$fieldNameOrId
    ) {
        return $this.fields 
        | Where-Object { ($_.name -eq $fieldNameOrId) -or ($_.id -eq $fieldNameOrId) }
        | Select-Object -First 1
    }

    [void]RemoveItem(
        [ProjectV2Item]$item
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

    [ProjectV2Item]AddItemByContentId(
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
                        $([ProjectV2Item]::FetchSubQuery)
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

        $item = [ProjectV2Item]::new($result.addProjectNextItem.projectNextItem, $this.client)

        # If the item already exists in the board the API just returns the same item with the same id
        # In this case, remove the item that already exists
        $this.items = $this.items | Where-Object { $_.id -ne $item.id }

        $item.SetParent($this)
        $this.items += $item

        return $item
    }
}

class ProjectV2Item: GraphQLObjectBase {
    # The Issue/PR this corresponds to
    [ItemContent]$Content

    [ProjectV2FieldValue[]]$FieldValues

    hidden [ProjectV2]$Parent

    hidden [GraphQLClient]$Client

    # Constructor from value returned by $FetchSubQuery
    ProjectV2Item(
        $queryResult,
        [GraphQLClient]$client
    ) {
        $this.id = $queryResult.id
        $this.content = [ItemContent]::new($queryResult.content, $client)

        $this.fieldValues = $queryResult.fieldValues.edges.node | ForEach-Object {
            $fieldValue = [ProjectV2FieldValue]::new($_)

            # Only populate handled types
            if ($fieldValue.Id) {
                return $fieldValue
            }
        }

        $this.client = $client
    }

    [void]SetParent(
        [ProjectV2]$parent
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

        $value = $this.fieldValues | Where-Object { $_.parent.id -eq $field.id }

        if (-not $value) {
            return $null
        }

        return $value.name ?? $value.value
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

        $valueInput = $field.SetValueSubQuery($value, $enableOptionLikeMatching)

        $query = "
            mutation {
                updateProjectV2ItemFieldValue(
                    input: {
                        projectId: `"$($this.parent.id)`"
                        itemId: `"$($this.id)`"
                        fieldId: `"$($field.id)`"
                        value: {
                            $valueInput
                        }
                    }
                ) {
                    projectV2Item {
                        id
                    }
                }
            }
        "

        try {
            $_ = $this.client.MakeRequest($query)
        } catch [Exception] {
            Write-Error "Failed to set field value for item $($this.id)"
            throw $_
        }

        if ($this.HasValueForField($fieldNameOrId)) {
            $this.fieldValues | Where-Object { $_.fieldId -eq $field.id } | ForEach-Object { $_.value = $targetValue } 
        } else {
            $this.fieldValues += [ProjectV2FieldValue]::new($field, $value)
        }

        return $true
    }

    static [string]$FetchSubQuery = "
        id
        fieldValues(first: $global:maxSupportedProjectFields) {
            edges {
                node {
                    $([ProjectV2FieldValue]::FetchSubQuery)
                }
            }
        }
        content {
            $([ItemContent]::FetchSubQuery)
        }
    "
}

class ProjectV2Field: GraphQLObjectBase {
    [string]$Name

    [string]$DataType
    [string]$Type

    [ProjectV2FieldOption[]]$Options

    # Constructor from value returned by $FetchSubQuery
    ProjectV2Field($queryResult) {
        $this.id = $queryResult.id
        $this.name = $queryResult.name
        $this.datatype = $queryResult.datatype
        $this.type = $queryResult.__typename

        if ($queryResult.options) {
            $this.options = $queryResult.options | ForEach-Object {
                [ProjectV2FieldOption]::new($_.id, $_.name)
            }
        }
    }

    [ProjectV2FieldOption]GetFieldOption(
        [string]$optionNameOrId
    ) {
        return $this.GetFieldOption($optionNameOrId, $false)
    }

    [ProjectV2FieldOption]GetFieldOption(
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

    [string]SetValueSubQuery([string]$value, [bool]$enableOptionLikeMatching) {
        if (-not $value) {
            $targetValue = ""
        } elseif ($this.options) {
            $option = $this.GetFieldOption($value, $enableOptionLikeMatching)
            if (-not $option) {
                return ""
            }

            $targetValue = $option.id
        } else {
            $targetValue = $value
        }

        if ($this.datatype -eq "DATE") {
            return "date: `"$targetValue`""
        }
        if ($this.datatype -eq "NUMBER") {
            return "number: $targetValue"
        }
        if ($this.datatype -eq "SINGLE_SELECT") {
            return "singleSelectOptionId: `"$targetValue`""
        }
        if ($this.datatype -eq "TEXT") {
            return "text: `"$targetValue`""
        }
        
        throw "Updating value of type $($this.datatype) is not currently supported"
    }

    # Note: this must come before FetchSubQuery or it will be evaluated as an empty string
    static [string]$CommonQueryProperties = "
        id
        name
        dataType
    "

    # See https://docs.github.com/en/graphql/reference/unions#projectv2fieldconfiguration
    static [string]$FetchSubQuery = "
        __typename
        ... on ProjectV2Field {
            $([ProjectV2Field]::CommonQueryProperties)
        }
        ... on ProjectV2IterationField {
            $([ProjectV2Field]::CommonQueryProperties)
        }
        ... on ProjectV2SingleSelectField {
            $([ProjectV2Field]::CommonQueryProperties)
            options {
                id 
                name
            }
        }
    "
}

class ProjectV2FieldOption: GraphQLObjectBase {
    [string]$Name

    ProjectV2FieldOption(
        [string]$id,
        [string]$name
    ) {
        $this.id = $id
        $this.name = $name
    }
}

class ProjectV2FieldValue {
    # Check this field on the queryResult constructor to see if the subtype is handled or not
    [string]$Id

    [string]$FieldId

    [string]$Value

    # For single-select, this is the friendly name of the value
    [string]$Name

    ProjectV2FieldValue(
        [ProjectV2Field]$parent,
        [string]$value
    ) {
        $this.fieldId = $parent.id

        $option = $parent.GetFieldOption($value)
        if ($option) {
            $this.value = $option.id
            $this.name = $option.name
        } else {
            $this.value = $value
        }
    }

    ProjectV2FieldValue(
        $queryResult
    ) {
        $this.fieldId = $queryResult.field.id

        $this.value = $queryResult.value
        $this.name = $queryResult.name
    }

    # Note: this must come before FetchSubQuery or it will be evaluated as an empty string
    static [string]$CommonQueryProperties = "
        field {
            ... on ProjectV2Field {
                id
            }
            ... on ProjectV2IterationField {
                id
            }
            ... on ProjectV2SingleSelectField {
                id
            }
        }
        id
    "

    # There are a lot more types, but not needed so far :)
    static [string]$FetchSubQuery = "
        ... on ProjectV2ItemFieldDateValue {
            $([ProjectV2FieldValue]::CommonQueryProperties)
            value: date
        }
        ... on ProjectV2ItemFieldNumberValue {
            $([ProjectV2FieldValue]::CommonQueryProperties)
            value: number
        }
        ... on ProjectV2ItemFieldSingleSelectValue {
            $([ProjectV2FieldValue]::CommonQueryProperties)
            value: optionId
            name
        }
        ... on ProjectV2ItemFieldTextValue {
            $([ProjectV2FieldValue]::CommonQueryProperties)
            value: text 
        }
    "
}

function Get-ProjectItems {
    [CmdletBinding()]
    [OutputType([ProjectV2Item[]])]
    param(
        [string]$org,
        [int]$projectNumber,
        [GraphQLClient]$client
    )

    $pageSize = 100

    $query = "
        query (`$id: Int!, `$org: String!, `$cursor: String) {
            organization(login: `$org) {
                projectV2(number: `$id) {
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
        Write-Verbose $query
        $result = $client.MakeRequest($query, $variables)

        $itemIds = $result.organization.projectV2.items.edges.node.id

        Get-ProjectItemsByIdBatch -ids $itemIds -client $client

        $pageInfo = $result.organization.projectV2.items.pageInfo

        $variables.cursor = $pageInfo.endCursor
    } while ($pageInfo.hasNextPage)
}

# For performance, we load ProjectV2Items in batches. This causes issues with authorization
# if the current token is allowed to access some issues, but not others - this can easily happen
# if the project has items from multiple orgs. In that case we filter out the forbidden items
# and just ignore them.
function Get-ProjectItemsByIdBatch {
    [CmdletBinding()]
    [OutputType([ProjectV2Item[]])]
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
                ... on ProjectV2Item {
                    $([ProjectV2Item]::FetchSubQuery)
                }
            }"
        }
    
        "query {
            $($subQueries -join "`n")
        }"
    }

    $query = Get-BatchQuery -ids $ids

    try {
        Write-Verbose $query
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
        [ProjectV2Item]::new($item, $client)
    }
    | Where-Object { $_.content.type -ne "DraftIssue" }
}

function Get-ProjectFields {
    [CmdletBinding()]
    [OutputType([ProjectV2Field[]])]
    param(
        [string]$org,
        [int]$projectNumber,
        [GraphQLClient]$client
    )

    $query = "
        query (`$id: Int!, `$org: String!) {
            organization(login: `$org) {
                projectV2(number: `$id) {
                    fields(first: $global:maxSupportedProjectFields) {
                        edges {
                            node {
                                $([ProjectV2Field]::FetchSubQuery)
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

    if ($result.organization.projectV2.fields.pageInfo.hasNextPage) {
        throw "Could not fetch fields for Project #$projectNumber - it has more than the supported limit of $global:maxSupportedProjectFields fields"
    }

    $result.organization.projectV2.fields.edges.node 
    | ForEach-Object { [ProjectV2Field]::new($_) }
    | Where-Object { -not (Is-IgnoredField $_) }
}

function Is-IgnoredField {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [ProjectV2Field]$field
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
    [OutputType([ProjectV2])]
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
                projectV2(number: `$id) {
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

    $project = [ProjectV2]::new(
        $result.organization.projectV2.id,
        $result.organization.projectV2.title,
        $result.organization.projectV2.number,
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
                projectV2(first: 100, after: `$cursor) {
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
