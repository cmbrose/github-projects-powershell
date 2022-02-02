# github-projects-powershell
Utility scripts and classes for working with GitHub projects. Specifically supporting ProjectsVNext and actions.

# Usage

> A note on naming: it's a bit confusing to specify "Project" and "Project vNext" to denote "old" and "new" project types. So instead "old" projects are called "Boards" and "new" projects are "Projects".

## Common Types

### ItemContent

A single item on a Project or Board which corresponds to a single Issue or Pull Request.

> Note: `Board`s may also have notes, which are different than `ItemContent`. A `Board` card will either have an `ItemContent` or a note, never both.

#### Properties

`[string] $id`: the GraphQL `id` - note this is *not* the same as the number.

`[int] $number`: the Issue or Pull Request number. This is what is usually referred to as the "id".

`[string] $repository`: the full repository name in the form `org/repo`

`[string] $type`: `"Issue"` or `"Pull Request"`

`[string] $author`: the Issue or Pull Request author login

`[string] $title`: the Issue or Pull Request title

`[string] $body`: the Issue or Pull Request body

`[string] $createdAt`: the datetime the Issue or Pull Request created at

`[bool] $closed`: if the Issue or Pull Request is closed

`[Label[]] $labels`: the `Label`s on the Issue or Pull Request

`[Comment[]] $comments`: the `Comment`s on the Issue or Pull request. Note: this is `$null` by default, call `$itemContent.FetchComments()` to populate the field.

#### Methods

> Note: methods marked with * will also perform a GraphQL mutation and update the server data.

`[void]Close()` *: closes the Issue or Pull Request.

`[void]AddLabel([Label]$label)` *: adds the `Label` the Issue or Pull Request.

`[void]RemoveLabel([Label]$label)` *: removes the `Label` from the Issue or Pull Request.

`[void]UpdateBody([string]$newBody)` *: updates the Issue or Pull Request body to `$newBody`. Note: double quotes in `$newBody` will be escaped automaticially - they should not be escaped before calling this.

`[void]AddComment([string]$bodyText)` *: adds a new `Comment` to the `ItemContent` and returns it. The new `Comment` will appear in `.Comments` if `Comment`s have already been fetched. Note: double quotes in `$bodyText` will be escaped automaticially - they should not be escaped before calling this.

`[void]FetchComments()`: fetches the Issue or Pull Request's `Comment`s. The `.Comments` field will be `$null` unless this is called.

### Comment

A single comment on an `ItemContent` - an Issue or Pull Request.

> Note: this type is currently only accessible through it's parent `ItemContent`, it cannot be directly fetched.

#### Properties

`[string] $id`: The GraphQL `id`.

`[string] $body`: The comment body.

`[string] $author`: The `Comment` author's login.

`[string] $createdAt`: The UTC time the `Comment` was created at.

#### Methods

`[void]UpdateBody([string]$newBody)` *: updates the `Comment`'s body to `$newBody`. Note: double quotes in `$newBody` will be escaped automaticially - they should not be escaped before calling this.

### Label

The configuration for a label in a repo. Multiple `ItemContent`s can reference the same `Label`.

#### Properties

`[string] $id`: The GraphQL `id`

`[string] $name`: The name (display text) of the `Label`

`[string] $color`: The hex code color of the `Label` background

### Repository

#### Properties

`[string] $id`: The GraphQL `id`

`[int] $name`: The repository's name

`[Label[]] $labels`: The labels that exist in the repository

#### Methods

`[Label]AddLabel([string]$name, [string]$color)` *: creates a new label with the given `name` and `color` (a hex color, e.g. `1d76db`) in the specified repository and returns the created `Label`. Will throw if a label with `name` already exists.

`[void]DeleteLabel([string]$labelNameOrId)` *: permanently deletes the label with the given `name` or GraphQL `id` from the repo.

## Projects

### Project
The top level entity for a Project vNext which contains the Fields and Items

#### Properties

`[string] $id`: The GraphQL `id` - note this is *not* the same as the number.

`[ProjectField[]] $fields`: The `ProjectField`s

`[ProjectItem[]] $items`: The `ProjectItem`s

`[string] $title`: The title (aka name) of the `Project`

`[int] $number`: The number of the `Project`

#### Methods

> Note: methods marked with * will also perform a GraphQL mutation and update the server data.

`[ProjectField]GetField([string]$fieldNameOrId)`: returns the single `ProjectField` with matching `name` or `id` property (both are compared).

`[void]RemoveItem([ProjectItem]$item)` *: removes the `ProjectItem` from the Project (by `id`)

`[ProjectItem]AddItemByContentId([string]$contentId)` *: adds a new `ProjectItem` to the project containing an `ItemContent` with the given id and returns the `ProjectItem`. If the `ProjectItem` already exists this will effectively no-op (although the GraphQL mutation is still run).

### ProjectItem
A single item (row/card) in a `Project`. It contains a single `ItemContent` which corresponds to an actual Issue or Pull Request. It also contains values for the `ProjectFields`.

> Note: both `ProjectItem` and `ItemContent` have an `id` property. `ProjectItem`s are associated with a single `Project`, while `ItemContent` can be across multiple `Projects`. So `ProjectItem.id` will only be consistent within a `Project`. A `ProjectItem` with the same `ItemContent` on a different `Project` will have a different `id`.

#### Properties

`[string] $id`: The GraphQL `id`

`[ItemContent] $content`: The `ItemContent` which corresponding to an Issue or Pull Request

`[ProjectFieldValue[]] $fieldValues`: The `ProjectFieldValue`s

#### Methods

`[bool]HasValueForField([string]$fieldNameOrId)`: returns `$true` if the `ProjectItem` has a value for the specified `ProjectField`.

`[string]GetFieldValue([string]$fieldNameOrId)`: returns the value for the specified `ProjectField` or `$null` if not set.

`[bool]TrySetFieldValue([string]$fieldNameOrId, [string]$value, [bool]$enableOptionLikeMatching=$false)` *: sets the value for the specified `ProjectField` to `$value`, overridding if already set. If the `ProjectField` is single-value then `$value` can be the option `name` or `id`. If `$enableOptionLikeMatching` is `$true` and the `ProjectField` is single-select then `$value` can match `name` using `-like` syntax.

### ProjectField
A single field on the Project (a column on the table view). Single-select `ProjectField`s with have an `options` property containing a list of `ProjectFieldOption`s which give the names of the possible values of the `ProjectField`.

#### Properties

`[string] $id`: The GraphQL `id`

`[string] $name`: The name of the `ProjectField`

`[ProjectFieldOption[]] $options`: The `ProjectFieldOption`s (only set for single-select `ProjectFields`)

#### Methods

`[string]GetFieldOption([string]$optionNameOrId, [bool]$enableNameLikeMatching=$false)` *: searches a single-select `ProjectField` for a `ProjectFieldOption` matching `$optionNameOrId`. If `$enableNameLikeMatching` is `$true` then `$optionNameOrId` can match `name` using `-like` syntax. If the `ProjectField` isn't single-select, returns `$null`

### ProjectFieldOption
A single option for a single-select `ProjectField`

#### Properties

`[string] $id`: The GraphQL `id`

`[string] $name`: The name of the `ProjectFieldOption` - this is the value the visible in the UI

### ProjectFieldValue
The value of a `ProjectField` for a partiicular `ProjectItem`

#### Properties

`[string] $fieldId`: The `id` of the `ProjectField` this value maps to

`[string] $value`: The value - for single-select `ProjectField`s this is the `id` of the `ProjectFieldOption`, otherwise it is a text value

### Examples

```powershell
# Setup
Import-Module .\types\project-vnext.psm1

# Load Project
$proj = Get-Project -org my-org -projectNumber 123 -token $token

# List field names
$proj.fields.name

# List options for a single-select field
$proj.GetField("MyField").options.name

# List repo and # for project items
$proj.items.content | % { "$($_.repository)#$($_.number)" }

# Get/set the Status for a specific item
$proj.items | where { $_.content.number -eq 1234 } | % { $_.GetFieldValue("Status") }
$proj.items | where { $_.content.number -eq 1234 } | % { $_.TrySetFieldValue("Status", "Done") }

# Remove items from the project
$proj.items | where { $_.content.number -eq 1234 } | % { $proj.RemoveItem($_) }

# Add item to the project
$item = $otherProject.items | where { $_.content.number -eq 1234 }
$proj.AddItemByContentId($item.content.id)
```

## Boards

### Board
The top level entity for an "old" Project which contains the set of columns (which in turn contain the cards)

#### Properties

`[string] $id`: The GraphQL `id` - note this is *not* the same as the number.

`[BoardColumn[]] $columns`: the list of `BoardColumn`s

`[string] $org`: the organization the board belongs to

`[string] $repoName`: the repository the board belongs to or `$null` if the board is at an organization level

#### Methods

`[BoardColumn]GetColumn([string]$columnIdOrName)`: returns the single `BoardColumn` matching the specified value (search both `name` and `id`)

`[BoardCard]AddNoteToColumn([string]$note, [string]$columnIdOrName, [bool]$moveIfExists=$false)` *: adds a new note to the `Board` and returns the `BoardCard` containing it. If a note already exists on the `Board` with the same content, will `throw` unless `$moveIfExists` is `$true` in which case it moves the card.

`[BoardCard]AddContentToColumn([ItemContent]$content, [string]$columnIdOrName, [bool]$moveIfExists=$false)` *: adds a new `ItemContent` to the `Board` and returns the `BoardCard` containing it. If the Issue or Pull Request already exists on the `Board` with the same content, will `throw` unless `$moveIfExists` is `$true` in which case it moves the card. If the `ItemContent` is for another organization, the `ItemContent` is added as a note instead with the value of the url to that Issue or Pull Request.

### BoardColumn
A single column of a `Board` which contains a set of `BoardCard`s

#### Properties

`[string] $id`: The GraphQL `id`

`[BoardCard[]] $cards`: the list of `BoardCard`s

`[string] $name`: the name of the column - this is what is shown in the UI

### BoardCard
A single card of a `Board` which contains either an `ItemContent` for an Issue or Pull Request, or a note (but not both).

#### Properties

`[string] $id`: The GraphQL `id`

`[ItemContent] $content`: the `ItemContent` of a card

`[string] $note`: the string content of a note

### Examples

```powershell
# Setup
Import-Module .\types\board.psm1

# Load Board
$repoBoard = Get-RepoBoard -org my-org -repoName my-repo -boardNumber 123 -token $token
$orgBoard = Get-OrganizationBoard -org my-org -boardNumber 123 -token $token

# List column names
$board.columns.name

# Get all cards on the Board
$board.columns.cards

# Get all cards by status
$board.GetColumn("Done").cards

# List repo and # for project items (the where filters notes)
$board.columns.cards.content | where { $_.content.id } | % { "$($_.repository)#$($_.number)" }

# Get the status for a specific card
$board.columns | where { $_.cards | where { $_.content.number -eq 1234 } } | % name

# Move a specific card to a different column
$board.columns.cards | where { $_.content.number -eq 1234 } | % { $board.AddContentToColumn($_.content, "Done", $true) }

# Add item to the board (throws if already on the board)
$card = $otherBoard.columns.cards | where { $_.content.number -eq 1234 }
$board.AddContentToColumn($card.content.id, "To do")

# Add note to the board (throws if already on the board)
$board.AddNoteToColumn("my note", "Notes")
```
