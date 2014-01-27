/*
 Copyright 2011 Marko Karppinen & Co. LLC.
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 
 MKCNSManagedObjectModelAdditions.h
 Created by Nikita Zhuk on 22.1.2011.
 */

#import <CoreData/CoreData.h>


@protocol MKCNSRelationshipDescriptionDependencyFilter<NSObject>
- (BOOL)includeRelationship:(NSRelationshipDescription *)relationship;
@end

@interface NSManagedObjectModel(MKCNSManagedObjectModelAdditions)

/**
 Array of NSEntityDescription objects, sorted in topological order
 based on relationships between entity descriptions.
 If there are cyclic dependencies, a nil is returned.
 This method counts all relationships as dependencies if they are not marked as being 'transient'.
 */

- (NSArray *) entitiesInTopologicalOrder;

/*
 Same as entitiesInTopologicalOrder, but uses the given dependencyFilter to decide whether a
 relationship should be counted as dependency or not.
 */
- (NSArray *) entitiesInTopologicalOrderUsingDependencyFilter:(id<MKCNSRelationshipDescriptionDependencyFilter>) dependencyFilter;

/*
 Apply given model-delta file to the model.
 Return YES if the delta was applied successfully.
 
 Model-delta file is expected to be JSON containing either a single operation or an array of operations.
 Operation:
    "operation": "add entity" (add a new entity to the model) or "extend entity" (add new properties to an existing model entity) (string; required)
    "name": entity name (string; required)
    "className": name of custom class for the entity (used for "add entity" only; string; optional)
    "attributes": array of attribute-entry (optional)
    "relationships": array of relationship-entry (optional)
    "subentities": array of entity names (used for "add entity" only; optional)
 Attribute entry:
    "name": attribute name (string; required)
    "type": one of "NSUndefinedAttributeType", "NSInteger16AttributeType", "NSInteger32AttributeType", "NSInteger64AttributeType",
          "NSDecimalAttributeType", "NSDoubleAttributeType", "NSFloatAttributeType", "NSStringAttributeType", "NSBooleanAttributeType"
          "NSDateAttributeType", "NSBinaryDataAttributeType", "NSTransformableAttributeType", "NSObjectIDAttributeType"
          (string; required)
    "optional": boolean (optional)
    "indexed": boolean (optional)
 Relationship entry:
    "name": relationship name (string; required)
    "destination": name of destination entity (string; required)
    "inverse": name of inverse relationship on destination entity (string; optional, with warning if missing)
    "deleteRule": one of "NSNoActionDeleteRule", "NSNullifyDeleteRule", "NSCascadeDeleteRule", "NSDenyDeleteRule"
          (string; optional, with warning if missing - default "NSNullifyDeleteRule")
    "minCount": number (integer); optional
    "maxCount": number (integer); optional
    "optional": boolean (optional)
 */
- (BOOL)applyModelDelta:(NSString *)modelDeltaPath;


@end
