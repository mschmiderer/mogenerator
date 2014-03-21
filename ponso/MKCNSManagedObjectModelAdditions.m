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
 
 MKCNSManagedObjectModelAdditions.m
 Created by Nikita Zhuk on 22.1.2011.
 */

#import "MKCNSManagedObjectModelAdditions.h"
#import "MKCDAGNode.h"
#import <objc/runtime.h>


@interface MKCNSRelationshipDescriptionDefaultDependencyFilter : NSObject <MKCNSRelationshipDescriptionDependencyFilter> @end

@implementation MKCNSRelationshipDescriptionDefaultDependencyFilter

- (BOOL)includeRelationship:(NSRelationshipDescription *)relationship
{
	if([[relationship entity] isEqual:[relationship destinationEntity]])
	{
		// Relationship from entity to itself - ignore.
		return NO;
	}
	
	return ![relationship isTransient];
}

@end


@implementation NSManagedObjectModel(MKCNSManagedObjectModelAdditions)

- (NSArray *) entitiesInTopologicalOrderUsingDependencyFilter:(id<MKCNSRelationshipDescriptionDependencyFilter>) dependencyFilter
{
	// Wrap entitites in DAG nodes and place them all into dict for faster access
	NSMutableDictionary *entityNodes = [NSMutableDictionary dictionaryWithCapacity:[[self entities] count]];
	for (NSEntityDescription *entity in [self entities])
	{
		MKCDAGNode *node = [[[MKCDAGNode alloc] initWithObject:entity] autorelease];
		[entityNodes setObject:node forKey:[entity name]];
	}
	
	// Create DAG from entities based on their relationships
	MKCDAGNode *root = [[[MKCDAGNode alloc] initWithObject:nil] autorelease];
	
	for (NSEntityDescription *entity in [self entities])
	{
		MKCDAGNode *node = [entityNodes objectForKey:[entity name]];
		
		if(![root addNode:node])
		{
			NSLog(@"Couldn't add node of entity '%@' to root.", [entity name]);
			return nil;
		}
		
		for (NSRelationshipDescription *relationship in [[entity relationshipsByName] allValues])
		{
			BOOL shouldInclude = YES;
			
			if(dependencyFilter != nil)
			{
				shouldInclude = [dependencyFilter includeRelationship:relationship];
			}
			
			if(shouldInclude)
			{
				MKCDAGNode *childNode = [entityNodes objectForKey:[[relationship destinationEntity] name]];
				
				if(![node addNode:childNode])
				{
					NSLog(@"Couldn't add dependency '%@' -> '%@'. A cycle was detected.", [[relationship entity] name], [[relationship destinationEntity] name]);
					return nil;
				}
			}
		}
	}
	
	return root.objectsInTopologicalOrder;
}

- (NSArray *) entitiesInTopologicalOrder
{
	id defaultFilter = [[[MKCNSRelationshipDescriptionDefaultDependencyFilter alloc] init] autorelease];
	
	return [self entitiesInTopologicalOrderUsingDependencyFilter:defaultFilter];
}

- (BOOL)applyModelDelta:(NSString *)modelDeltaPath
{
  // NSJSONSerialization is 10.7+, so if we want to push this back to github we'll have to either reimplement with a third-party JSON library
  // or make this feature 10.7+

  BOOL success = NO;
  NSData *data = [NSData dataWithContentsOfFile:modelDeltaPath];
  if (! data) {
    NSLog(@"Could not load model-delta file at '%@'", modelDeltaPath);
    goto EXIT;
  }
  NSError *error = nil;
  id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (! root) {
    NSLog(@"Could not parse JSON data in model-delta file at '%@': %@", modelDeltaPath, error);
    goto EXIT;
  }
  if ([root isKindOfClass:[NSArray class]]) {
    success = YES;
    for (id op in root) {
      success = [self applyModelDeltaOperation:op] && success;
    }
  } else {
    success = [self applyModelDeltaOperation:root];
  }

  success = success && [self completeRelationshipInverses];
  
EXIT:
  return success;
}


- (BOOL)completeRelationshipInverses
{
  BOOL success = NO;
  
  NSArray *array = self.modelDeltaRelationshipInverses;
  for (NSDictionary *entry in array) {
    NSString *entityName = [entry objectForKey:@"entity"];
    NSString *relationshipName = [entry objectForKey:@"relationship"];
    NSString *destionationEntityName = [entry objectForKey:@"destEntity"];
    NSString *inverseName = [entry objectForKey:@"inverse"];
    NSEntityDescription *entity = [self.entitiesByName objectForKey:entityName];
    if (! entity) {
      NSLog(@"Model-delta: could not find entity '%@' to complete relationship '%@'", entityName, relationshipName);
      goto EXIT;
    }
    NSRelationshipDescription *relationship = [entity.relationshipsByName objectForKey:relationshipName];
    if (! relationship) {
      NSLog(@"Model-delta: could not find relationship '%@' on entity '%@' for completion", relationshipName, entityName);
      goto EXIT;
    }
    NSEntityDescription *destEntity = [self.entitiesByName objectForKey:destionationEntityName];
    if (! destEntity) {
      NSLog(@"Model-delta: could not find destination entity '%@' to complete relationship '%@' on entity '%@'",
            destionationEntityName, relationshipName, entityName);
      goto EXIT;
    }
    NSRelationshipDescription *inverse = [destEntity.relationshipsByName objectForKey:inverseName];
    if (! inverse) {
      NSLog(@"Model-delta: could not find relationship '%@' on destination entity '%@' to complete relationship '%@' on entity '%@'",
            inverseName, destionationEntityName, relationshipName, entityName);
      goto EXIT;
    }
    
    relationship.inverseRelationship = inverse;
  }
  
  success = YES;
  
EXIT:
  
  return success;
}


- (BOOL)applyModelDeltaOperation:(id)op
{
  BOOL success = NO;
  
  if (! [op isKindOfClass:[NSDictionary class]]) {
    NSLog(@"Unexpected model-delta operation type: %@", NSStringFromClass([op class]));
    goto EXIT;
  }

  NSString *optype = [op objectForKey:@"operation"];
  if (! optype) {
    NSLog(@"Model-delta operation lacks an operation type: %@", op);
    goto EXIT;
  }
  if ([@"add entity" isEqualToString:optype]) {
    success = [self applyModelDeltaAddEntityOperation:op];
  } else if ([@"extend entity" isEqualToString:optype]) {
    success = [self applyModelDeltaExtendEntityOperation:op];
  } else {
    NSLog(@"Model-delta operation has unexpected operation type (%@): %@", optype, op);
  }
  
EXIT:
  return success;
}


- (BOOL)applyCommonOperation:(NSMutableDictionary *)op toEntity:(NSEntityDescription *)entity
{
  BOOL success = NO;
  
  id attributes = [op objectForKey:@"attributes"];
  if (attributes) {
    if (! [attributes isKindOfClass:[NSArray class]]) {
      NSLog(@"Model-delta operation has unexpected attributes (%@): %@", attributes, op);
      goto EXIT;
    }
    if (! [self addAttributes:attributes toEntity:entity]) {
      goto EXIT;
    }
  }
  [op removeObjectForKey:@"attributes"];
  
  id relationships = [op objectForKey:@"relationships"];
  if (relationships) {
    if (! [relationships isKindOfClass:[NSArray class]]) {
      NSLog(@"Model-delta operation has unexpected relationships (%@): %@", relationships, op);
      goto EXIT;
    }
    if (! [self addRelationships:relationships toEntity:entity]) {
      goto EXIT;
    }
  }
  [op removeObjectForKey:@"relationships"];
  
  id subentities = [op objectForKey:@"subentities"];
  if (subentities) {
    if (! [subentities isKindOfClass:[NSArray class]]) {
      NSLog(@"Model-delta operation has unexpected subentities (%@): %@", subentities, op);
      goto EXIT;
    }
    NSMutableArray *children = [entity.subentities mutableCopy];
    for (NSString *name in subentities) {
      NSEntityDescription *child = [self.entitiesByName objectForKey:name];
      if (! child) {
        NSLog(@"Model-delta operation specifies unknown subentity: %@", name);
        goto EXIT;
      }
      [children addObject:child];
    }
    entity.subentities = children;
  }
  [op removeObjectForKey:@"subentities"];
  
  id subClassName = [op objectForKey: @"managedObjectSubclass"];
  if (subClassName) {
    // preserve original classname so we can revert later
    NSMutableDictionary *newUserInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:entity.managedObjectClassName, @"originalClassName", nil];
    if (entity.userInfo) {
      [newUserInfo addEntriesFromDictionary:entity.userInfo];
    }
    [entity setUserInfo:newUserInfo];
    [entity setManagedObjectClassName: subClassName];
    [op removeObjectForKey:@"managedObjectSubclass"];
  }
  
  if (op.count > 0) {
    NSLog(@"Model-delta operation contains unknown keys:");
    for (NSString *key in op.allKeys) {
      NSLog(@"\t%@", key);
    }
    goto EXIT;
  }
  
  success = YES;
  
EXIT:
  return success;
}


- (BOOL)applyModelDeltaAddEntityOperation:(NSDictionary *)op
{
  BOOL success = NO;
  
  NSMutableDictionary *dict = [op mutableCopy];
  [dict removeObjectForKey:@"operation"];
  
  id name = [op objectForKey:@"name"];
  if (! name) {
    NSLog(@"Model-delta operation lacks entity name: %@", op);
    goto EXIT;
  }
  if (! [name isKindOfClass:[NSString class]]) {
    NSLog(@"Model-delta operation has unexpected entity name (%@): %@", name, op);
    goto EXIT;
  }
  [dict removeObjectForKey:@"name"];
  
  NSEntityDescription *entity = [[[NSEntityDescription alloc] init] autorelease];
  assert(entity);
  entity.name = name;
  
  id className = [op objectForKey:@"className"];
  if (className) {
    if (! [className isKindOfClass:[NSString class]]) {
      NSLog(@"Model-delta operation has unexpected class name (%@): %@", className, op);
      goto EXIT;
    }
    entity.managedObjectClassName = className;
  } else {
    NSLog(@"WARNING: model-delta entity '%@' lacks a managed-object class name", name);
  }
  [dict removeObjectForKey:@"className"];
  
  success = [self applyCommonOperation:dict toEntity:entity];
  if (! success) {
    goto EXIT;
  }
  
  NSMutableArray *entities = [self.entities mutableCopy];
  [entities addObject:entity];
  self.entities = entities;
  success = YES;
  
EXIT:
  
  return success;
}


- (BOOL)addAttributes:(NSArray *)attributes toEntity:(NSEntityDescription *)entity
{
  BOOL success = NO;
  
  for (id entry in attributes) {
    if (! [entry isKindOfClass:[NSDictionary class]]) {
      NSLog(@"Model-delta attributes has unexpected entry (%@): %@", entry, attributes);
      goto EXIT;
    }
    NSMutableDictionary *dict = [entry mutableCopy];
    id name = [dict objectForKey:@"name"];
    if (! name) {
      NSLog(@"Model-delta attributes entry lacks attribute name: %@", entry);
      goto EXIT;
    }
    if (! [name isKindOfClass:[NSString class]]) {
      NSLog(@"Model-delta attributes entry has unexpected attribute name (%@): %@", name, entry);
      goto EXIT;
    }
    [dict removeObjectForKey:@"name"];
    
    id attrTypeName = [dict objectForKey:@"type"];
    if (! attrTypeName) {
      NSLog(@"Model-delta attributes entry lacks attribute type: %@", entry);
      goto EXIT;
    }
    if (! [attrTypeName isKindOfClass:[NSString class]]) {
      NSLog(@"Model-delta attributes entry has unexpected attribute type (%@): %@", attrTypeName, entry);
      goto EXIT;
    }
    NSAttributeType attrType = [self attributeTypeFromName:attrTypeName];
    if (attrType == NSUndefinedAttributeType) {
      NSLog(@"Model-delta attributes entry has unexpected attribute type (%@): %@", attrTypeName, entry);
      goto EXIT;
    }
    [dict removeObjectForKey:@"type"];
    
    BOOL optional = [[dict objectForKey:@"optional"] boolValue];
    [dict removeObjectForKey:@"optional"];
    
    BOOL indexed = [[dict objectForKey:@"indexed"] boolValue];
    [dict removeObjectForKey:@"indexed"];
    
    if (dict.count > 0) {
      NSLog(@"Model-delta attributes entry contains unknown keys:");
      for (NSString *key in dict.allKeys) {
        NSLog(@"\t%@", key);
      }
      goto EXIT;
    }
    
    NSAttributeDescription *attribute = [[[NSAttributeDescription alloc] init] autorelease];
    attribute.attributeType = attrType;
    attribute.name = name;
    attribute.optional = optional;
    attribute.indexed = indexed;
    
    NSMutableArray *entityProperties = [entity.properties mutableCopy];
    [entityProperties addObject:attribute];
    entity.properties = entityProperties;
  }
  
  success = YES;
  
EXIT:
  
  return success;
}


- (NSAttributeType)attributeTypeFromName:(NSString *)name
{
  if ([@"NSInteger16AttributeType" isEqualToString:name]) {
    return NSInteger16AttributeType;
  }
  if ([@"NSInteger32AttributeType" isEqualToString:name]) {
    return NSInteger32AttributeType;
  }
  if ([@"NSInteger64AttributeType" isEqualToString:name]) {
    return NSInteger64AttributeType;
  }
  if ([@"NSDecimalAttributeType" isEqualToString:name]) {
    return NSDecimalAttributeType;
  }
  if ([@"NSDoubleAttributeType" isEqualToString:name]) {
    return NSDoubleAttributeType;
  }
  if ([@"NSFloatAttributeType" isEqualToString:name]) {
    return NSFloatAttributeType;
  }
  if ([@"NSStringAttributeType" isEqualToString:name]) {
    return NSStringAttributeType;
  }
  if ([@"NSBooleanAttributeType" isEqualToString:name]) {
    return NSBooleanAttributeType;
  }
  if ([@"NSDateAttributeType" isEqualToString:name]) {
    return NSDateAttributeType;
  }
  if ([@"NSBinaryDataAttributeType" isEqualToString:name]) {
    return NSBinaryDataAttributeType;
  }
  if ([@"NSTransformableAttributeType" isEqualToString:name]) {
    return NSTransformableAttributeType;
  }
  if ([@"NSObjectIDAttributeType" isEqualToString:name]) {
    return NSObjectIDAttributeType;
  }
  return NSUndefinedAttributeType;
}


- (BOOL)addRelationships:(NSArray *)relationships toEntity:(NSEntityDescription *)entity
{
  BOOL success = NO;
  
  for (id entry in relationships) {
    if (! [entry isKindOfClass:[NSDictionary class]]) {
      NSLog(@"Model-delta relationships has unexpected entry (%@): %@", entry, relationships);
      goto EXIT;
    }
    NSMutableDictionary *dict = [entry mutableCopy];
    id name = [dict objectForKey:@"name"];
    if (! name) {
      NSLog(@"Model-delta relationships entry lacks relationship name: %@", entry);
      goto EXIT;
    }
    if (! [name isKindOfClass:[NSString class]]) {
      NSLog(@"Model-delta relationships entry has unexpected relationship name (%@): %@", name, entry);
      goto EXIT;
    }
    [dict removeObjectForKey:@"name"];
    
    id destEntityName = [dict objectForKey:@"destination"];
    if (! destEntityName) {
      NSLog(@"Model-delta relationships entry lacks destination entity: %@", entry);
      goto EXIT;
    }
    if (! [destEntityName isKindOfClass:[NSString class]]) {
      NSLog(@"Model-delta relationships entry has unexpected destination entity name (%@): %@", destEntityName, entry);
      goto EXIT;
    }
    NSEntityDescription *destEntity = [self.entitiesByName objectForKey:destEntityName];
    if (! destEntity) {
      NSLog(@"Model-delta relationships entry specifies entity '%@' but no such entity found", destEntityName);
      goto EXIT;
    }
    [dict removeObjectForKey:@"destination"];
    
    id inverseName = [dict objectForKey:@"inverse"];
    NSRelationshipDescription *inverse = nil;
    if (inverseName) {
      if (! [inverseName isKindOfClass:[NSString class]]) {
        NSLog(@"Model-delta relationships entry has unexpected inverse relationship name (%@): %@", inverseName, entry);
        goto EXIT;
      }
      [self.modelDeltaRelationshipInverses addObject:@{@"entity": entity.name,
                                                       @"relationship": name,
                                                       @"destEntity": destEntityName,
                                                       @"inverse": inverseName}];
    } else {
      NSLog(@"WARNING: model-delta relationship entry lacks an inverse relationship: %@", entry);
    }
    [dict removeObjectForKey:@"inverse"];
    
    id deleteRuleName = [dict objectForKey:@"deleteRule"];
    NSDeleteRule deleteRule = NSNullifyDeleteRule;
    if (deleteRuleName) {
      if (! [deleteRuleName isKindOfClass:[NSString class]]) {
        NSLog(@"Model-delta relationships entry has unexpected delete rule (%@): %@", deleteRuleName, entry);
        goto EXIT;
      }
      BOOL match = NO;
      deleteRule = [self deleteRuleFromName:deleteRuleName match:&match];
      if (! match) {
        NSLog(@"Model-delta relationships entry has unexpected delete rule (%@): %@", deleteRuleName, entry);
        goto EXIT;
      }
    } else {
      NSLog(@"WARNING: model-delta relationships entry lacks delete rule; using NSNullifyDeleteRule: %@", entry);
    }
    [dict removeObjectForKey:@"deleteRule"];
    
    NSUInteger minCount = [[dict objectForKey:@"minCount"] unsignedIntegerValue];
    [dict removeObjectForKey:@"minCount"];
    
    NSUInteger maxCount = [[dict objectForKey:@"maxCount"] unsignedIntegerValue];
    [dict removeObjectForKey:@"maxCount"];
    
    BOOL optional = [[dict objectForKey:@"optional"] boolValue];
    [dict removeObjectForKey:@"optional"];
    
    if (dict.count > 0) {
      NSLog(@"Model-delta relationships entry contains unknown keys:");
      for (NSString *key in dict.allKeys) {
        NSLog(@"\t%@", key);
      }
      goto EXIT;
    }
    
    NSRelationshipDescription *relationship = [[[NSRelationshipDescription alloc] init] autorelease];
    relationship.name = name;
    relationship.destinationEntity = destEntity;
    relationship.optional = optional;
    relationship.minCount = minCount;
    relationship.maxCount = maxCount;
    relationship.deleteRule = deleteRule;
    if (inverse) {
      relationship.inverseRelationship = inverse;
    }
    
    NSMutableArray *entityProperties = [entity.properties mutableCopy];
    [entityProperties addObject:relationship];
    entity.properties = entityProperties;
  }
  
  success = YES;
  
EXIT:
  
  return success;
}


- (NSDeleteRule)deleteRuleFromName:(NSString *)name match:(BOOL *)oMatch
{
  BOOL m = YES;
  BOOL *match = (oMatch ? oMatch : &m);
  if ([@"NSNoActionDeleteRule" isEqualToString:name]) {
    *match = YES;
    return NSNoActionDeleteRule;
  }
  if ([@"NSNullifyDeleteRule" isEqualToString:name]) {
    *match = YES;
    return NSNullifyDeleteRule;
  }
  if ([@"NSCascadeDeleteRule" isEqualToString:name]) {
    *match = YES;
    return NSCascadeDeleteRule;
  }
  if ([@"NSDenyDeleteRule" isEqualToString:name]) {
    *match = YES;
    return NSDenyDeleteRule;
  }
  *match = NO;
  return NSNullifyDeleteRule;
}


- (BOOL)applyModelDeltaExtendEntityOperation:(NSDictionary *)op
{
  BOOL success = NO;
  
  NSMutableDictionary *dict = [op mutableCopy];
  [dict removeObjectForKey:@"operation"];

  id name = [op objectForKey:@"name"];
  if (! name) {
    NSLog(@"Model-delta operation lacks entity name: %@", op);
    goto EXIT;
  }
  if (! [name isKindOfClass:[NSString class]]) {
    NSLog(@"Model-delta operation has unexpected entity name (%@): %@", name, op);
    goto EXIT;
  }
  [dict removeObjectForKey:@"name"];
  
  NSEntityDescription *entity = [self.entitiesByName objectForKey:name];
  if (! entity) {
    NSLog(@"Model-delta operation extends entity name '%@', but no such entity found", name);
    goto EXIT;
  }
  
  success = [self applyCommonOperation:dict toEntity:entity];
  if (! success) {
    goto EXIT;
  }

  success = YES;
  
EXIT:
  
  return success;
}


- (NSMutableArray *)modelDeltaRelationshipInverses
{
  @synchronized(self) {
    NSMutableArray *array = objc_getAssociatedObject(self, @"modelDeltaRelationshipInverses");
    if (! array) {
      array = [NSMutableArray array];
      objc_setAssociatedObject(self, @"modelDeltaRelationshipInverses", array, OBJC_ASSOCIATION_RETAIN);
    }
    return array;
  }
}

- (void)revertCustomSubclassNames {
  for (NSEntityDescription *anEntity in self.entities) {
    NSDictionary *entityUserInfo = anEntity.userInfo;
    NSString *originalClassName = [anEntity.userInfo objectForKey:@"originalClassName"];
    if (originalClassName) {
      anEntity.managedObjectClassName = originalClassName;
      
      // clear out user info dictionary
      if (entityUserInfo.count == 1) {
        anEntity.userInfo = nil;
        continue;
      }
      
      // preserve existing userInfo entries
      NSMutableDictionary *updatedUserInfo = [NSMutableDictionary dictionaryWithDictionary:entityUserInfo];
      [updatedUserInfo removeObjectForKey:@"originalClassName"];
      anEntity.userInfo = [[updatedUserInfo copy] autorelease];
    }
  }
}

@end
