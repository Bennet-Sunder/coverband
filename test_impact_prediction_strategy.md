# Incremental Request-to-Code Mapping Strategy

This document focuses specifically on the challenges and strategies for incrementally updating the request-to-code mapping when PRs introduce code changes (additions, modifications, deletions), without requiring full regeneration of the mapping.

## Core Challenge

The primary challenge is to efficiently maintain an accurate request-to-code mapping when code changes, without re-running all 20,000 E2E test cases. An effective strategy must:

1. Identify affected parts of the mapping
2. Update only those parts
3. Ensure no critical test coverage is lost

## Code Change Scenarios and Strategies

### 1. New Code Additions

**Challenge**: New methods or classes don't exist in the current mapping.

Let's examine two different scenarios for new code additions:

#### Scenario 1A: New method called by existing methods

```ruby
# PR adds a new method to an existing class
class Group
  # Existing methods...
  
  # New helper method added in PR
  def sanitize_description
    description.strip.gsub(/<script>.*?<\/script>/m, '')
  end
  
  # Existing method modified to call the new method
  def save_with_validation
    self.description = sanitize_description
    # ...rest of existing method...
  end
end
```

In this scenario, the new `sanitize_description` method will be called by the existing `save_with_validation` method. Since `save_with_validation` is already in your mapping, you could:

1. Identify that `save_with_validation` was modified
2. Run the tests that cover `save_with_validation` based on your existing mapping
3. The new `sanitize_description` method would be exercised by these tests
4. Your mapping would be updated to include the new method

This is a favorable case where you can effectively use your existing mapping to discover the new method.

#### Scenario 1B: New standalone method or entry point

```ruby
# PR adds a new API endpoint handler
class GroupsController
  # Existing methods...
  
  # Completely new endpoint added in PR
  def archive
    @group = Group.find(params[:id])
    @group.update(archived: true)
    render json: @group
  end
end

# Routes updated to add new endpoint
# config/routes.rb
resources :groups do
  member do
    post :archive  # New route
  end
end
```

This scenario is more challenging because:
1. The new `archive` method doesn't exist in your mapping
2. It introduces a completely new entry point (API endpoint)
3. No existing tests would exercise this path

**Strategies**:

1. **Parent Component Inference**:
   - Identify the class/module where new code is added (`GroupsController`)
   - Run tests that interact with this class/module
   - Update mapping to include the new method

2. **Static Code Analysis**:
   - Analyze routing and controller structure to identify new endpoints
   - Run tests for similar endpoints in the same controller
   - For new methods in models, run tests for the model

3. **Class/Module Coverage**:
   - When a new method is added to a class, run a sample of tests that cover different methods in that class
   - This works on the assumption that similar functionality often gets tested similarly

### 2. Code Modifications

**Challenge**: Modified methods may change behavior or execution paths.

```ruby
# Before PR
def validate_group_name(name)
  name.length <= 100
end

# After PR
def validate_group_name(name)
  name.length <= 100 && name.match?(/^[a-zA-Z0-9\s\-_]+$/)
end
```

**Strategies**:

1. **Direct Mapping Lookup**:
   - Use git diff to identify modified methods
   - Look up these methods in the existing mapping
   - Run the tests that previously covered these methods

2. **Optimization for Minor Changes**:
   - For changes to comments, logging, or formatting only
   - Consider skipping tests or running a reduced subset

### 3. Code Deletions

**Challenge**: Removed methods result in references to non-existent code in your mapping.

```ruby
# PR removes this method
def legacy_group_validation(group)
  # Old validation logic being deleted
end
```

**Strategies**:

1. **Mapping Cleanup**:
   - Remove deleted methods from the mapping
   - Run tests that previously covered the deleted methods to ensure nothing breaks

2. **Caller Impact Analysis**:
   - Identify methods that might have called the deleted method
   - Run tests covering those callers

### 4. Method Signature Changes

**Challenge**: Renamed methods or changed signatures can break the mapping.

```ruby
# Before PR
def process_group_members(members)
  # Process logic
end

# After PR (renamed method)
def process_group_membership(members)
  # Same/similar process logic
end
```

**Strategies**:

1. **Combined Approach**:
   - Treat as a deletion of the old method and addition of a new method
   - Run tests covering the old method name
   - Run tests covering the class/module for the new method

2. **Code Similarity Detection**:
   - Identify renamed methods through code similarity
   - Update mapping keys to reflect the new method name

## Technical Implementation Challenges

### 1. Accurate Method Identification from Git Diffs

Git diffs show line changes, not semantic method changes. Converting from one to the other requires parsing Ruby files to understand method boundaries and contexts.

### 2. Handling Partial Updates to the Mapping

When running a subset of tests, you need to merge new data with existing data without losing information.

### 3. Recognizing Method Moves Between Files

When methods move between files or classes, simple diff analysis may see it as deletion + addition rather than a move operation.

## Practical Implementation for Coverband

Based on your workspace structure, this approach could be implemented by extending:
- `analyze_diff.rb` to categorize code changes
- `predict_test_impact.rb` to implement the test selection strategies
- Creating a mapping maintenance module in `lib/coverband/utils/`

## Conclusion

Incrementally updating your request-to-code mapping is achievable through careful categorization of code changes and targeted test execution. The key factors for success are:

1. Accurate method-level change detection from git diffs
2. Smart test selection based on mapping history
3. Careful merging of new mapping data with existing data
4. Periodic full regeneration to prevent drift

By implementing these strategies, you can maintain an accurate mapping while significantly reducing the need to run all 20,000 tests for each code change.