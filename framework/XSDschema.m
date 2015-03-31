
//
//  XSDschema.m
//  xsd2cocoa
//
//  Created by Stefan Winter on 5/22/11.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//


#import "XSDschema.h"
#import "XSSimpleType.h"
#import "XSDcomplexType.h"
#import "XSDelement.h"
#import "MGTemplateEngine.h"
#import "ICUTemplateMatcher.h"
//#import "DDFrameworkWriter.h"
#import "XMLUtils.h"
#import "DDUncrustifyFormatter.h"

@interface XSDcomplexType (privateAccessors)
@property (strong, nonatomic) NSArray* globalElements;
@end

@interface XSDschema ()

@property (strong, nonatomic) NSURL* schemaUrl;
@property (strong, nonatomic) NSString* targetNamespace;
@property (strong, nonatomic) NSArray* allNamespaces;
@property (strong, nonatomic) NSArray* complexTypes;
@property (strong, nonatomic) NSArray* includedSchemas;
@property (strong, nonatomic) NSArray* simpleTypes;

@property (weak, nonatomic) XSDschema* parentSchema;

@property (strong, nonatomic) NSString* complexTypeArrayType;
@property (strong, nonatomic) NSString* readComplexTypeElementTemplate;
@property (strong, nonatomic) NSString* readerClassTemplateString;
@property (strong, nonatomic) NSString* readerClassTemplateExtension;
@property (strong, nonatomic) NSString* readerHeaderTemplateString;
@property (strong, nonatomic) NSString* readerHeaderTemplateExtension;
@property (strong, nonatomic) NSString* classTemplateString;
@property (strong, nonatomic) NSString* classTemplateExtension;
@property (strong, nonatomic) NSString* headerTemplateString;
@property (strong, nonatomic) NSString* headerTemplateExtension;
@property (strong, nonatomic) NSDictionary* additionalFiles;
@property (strong, nonatomic) NSString *targetNamespacePrefix;
@property (strong, nonatomic) DDUncrustifyFormatter* formatter;

@end

@implementation XSDschema {
    NSMutableDictionary* _knownSimpleTypeDict;
    NSMutableDictionary* _knownComplexTypeDict;
}

// Called when initializing the object from a node
- (id) initWithNode:(NSXMLElement*)node targetNamespacePrefix:(NSString*)prefix error:(NSError**)error  {
	self = [super initWithNode:node schema:nil];
    if(self) {
        /* Get namespaces and set derived class prefix */
        self.targetNamespace = [[node attributeForName: @"targetNamespace"] stringValue];
        self.allNamespaces = [node namespaces];
        [self setTargetNamespacePrefixOverride:prefix];
        
        
        /* Add basic simple types known in the built-in types */
        _knownSimpleTypeDict = [NSMutableDictionary dictionary];
        for(XSSimpleType *aSimpleType in [XSSimpleType knownSimpleTypesForSchema:self]) {
            [_knownSimpleTypeDict setValue: aSimpleType forKey: aSimpleType.name];
        }
        
        /* Add custom simple types */
        self.simpleTypes = [NSMutableArray array];
        
        /* Grab all elements that are in the schema base with the simpleType element tag */
        NSArray* stNodes = [node nodesForXPath: @"/schema/simpleType" error: error];

        /* Iterate through the found elements */
        for (NSXMLElement* aChild in stNodes) {
            XSSimpleType* aST = [[XSSimpleType alloc] initWithNode:aChild schema:self];
            [((NSMutableDictionary*)_knownSimpleTypeDict) setObject:aST forKey:aST.name];
            [((NSMutableArray*)self.simpleTypes) addObject:aST];
        }

        /* Add complex types */
        _knownComplexTypeDict = [NSMutableDictionary dictionary];
        self.complexTypes = [NSMutableArray array];
        NSArray* ctNodes = [node nodesForXPath: @"/schema/complexType" error: error];
        /* Iterate through the complex types found and create node elements for them */
        for (NSXMLElement* aChild in ctNodes) {
            XSDcomplexType* aCT = [[XSDcomplexType alloc] initWithNode:aChild schema:self];
            [((NSMutableDictionary*)_knownComplexTypeDict) setObject:aCT forKey:aCT.name];
            [((NSMutableArray*)self.complexTypes) addObject: aCT];
        }

        /* Add the globals elements */
        NSMutableArray* globalElements = [NSMutableArray array];
        NSArray* geNodes = [node nodesForXPath: @"/schema/element" error: error];
        for (NSXMLElement* aChild in geNodes) {
            XSDelement* anElement = [[XSDelement alloc] initWithNode: aChild schema: self];
            [globalElements addObject: anElement];
        }

        /* For each global element found, connect the type */
        for (XSDelement* anElement in globalElements) {
            id<XSType> aType = [anElement schemaType];
            /* For the type check if it is in our found complex types */
            if( [aType isMemberOfClass: [XSDcomplexType class]]) {
                ((XSDcomplexType*)aType).globalElements = [((XSDcomplexType*)aType).globalElements arrayByAddingObject: anElement];
            }
        }
	}
    
    /* Return our created object with all the elements and generated types */
	return self;
}

- (id) initWithUrl: (NSURL*) schemaUrl targetNamespacePrefix: (NSString*) prefix error: (NSError**) error {
    NSData* data = [NSData dataWithContentsOfURL: schemaUrl];
    /* If we do not have data present an instance error that we cannot open the xsd file at the given location */
    if(!data) {
        *error = [NSError errorWithDomain:@"XSDschema" code:1 userInfo:@{NSLocalizedRecoverySuggestionErrorKey: [NSString stringWithFormat:@"Cant open xsd file at %@", schemaUrl]}];
        return nil;
    }
    /* Create a document tree structure */
    NSXMLDocument* doc = [[NSXMLDocument alloc] initWithData: data options: 0 error: error];
    if(!doc) {
        return nil;
    }
    
    /* From the root element, grab the complex, simple, and elements into their respective arrays */
    self = [self initWithNode: [doc rootElement] targetNamespacePrefix: prefix error: error];
    /* Continue to setup the schema */
    if(self) {
        /* The location of where our schema is located */
        self.schemaUrl = schemaUrl;
        
        //handle includes & imports
        NSArray* iNodes = [[doc rootElement] nodesForXPath: @"/schema/include" error: error];
        NSArray* iNodes2 = [[doc rootElement] nodesForXPath: @"/schema/import" error: error];
        if(iNodes2.count) {
            NSMutableArray *newNodes = [iNodes2 mutableCopy];
            if(iNodes.count) {
                [newNodes addObjectsFromArray:iNodes];
            }
            iNodes = newNodes;
        }
        
        /* For the imported schemas, grab their complex and simple types of their elements */
        self.includedSchemas = [NSMutableArray array];
        for (NSXMLElement* aChild in iNodes) {

            id schemaLocation = [aChild attributeForName:@"schemaLocation"].stringValue;
            NSURL *url = [NSURL URLWithString:schemaLocation relativeToURL:schemaUrl];
            XSDschema *xsd = [[self.class alloc] initWithUrl:url targetNamespacePrefix:prefix error:error];
            if(!xsd) {
                return nil;
            }
            
            xsd.parentSchema = self;
            [((NSMutableArray*)self.includedSchemas) addObject: xsd];
            
            //also add their types to ours, because we fricking know them now :D
            for (XSDcomplexType *ct in xsd.complexTypes) {
                [(NSMutableDictionary*)_knownComplexTypeDict setObject:ct forKey:ct.name];
                [(NSMutableArray*)self.complexTypes addObject:ct];
            }
            //also add their types to ours, because we fricking know them now :D
            for (XSSimpleType *ct in xsd.simpleTypes) {
                [(NSMutableDictionary*)_knownSimpleTypeDict setObject:ct forKey:ct.name];
                [(NSMutableArray*)self.simpleTypes addObject:ct];
            }
        }
    }
    
    return self;
}

#pragma mark -

- (void)setTargetNamespacePrefixOverride:(NSString*)prefix {
    //set class prefix
    if(prefix != nil) {
        self.targetNamespacePrefix = prefix;
    } else {
        for (NSXMLNode *node in self.allNamespaces) {
            NSString* nsURI = node.stringValue;
            
            if([nsURI isEqualTo: self.targetNamespace]) {
                self.targetNamespacePrefix = node.name;
            }
        }
    }
    
    //fix prefix so it is empty or uppercase
    if(!self.targetNamespacePrefix) {
        self.targetNamespacePrefix = @"";
    }
    else {
        self.targetNamespacePrefix = [self.targetNamespacePrefix uppercaseString];
    }
}

- (void) addType: (XSDcomplexType*) cType {
    if([cType isKindOfClass:[XSDcomplexType class]]) {
        [((NSMutableDictionary*) _knownComplexTypeDict) setObject:cType forKey:cType.name];
        [((NSMutableArray*)self.complexTypes) addObject: cType];
    }
    else if([cType isKindOfClass:[XSSimpleType class]]) {
        [((NSMutableDictionary*) _knownSimpleTypeDict) setObject:cType forKey:cType.name];
        [((NSMutableArray*)self.simpleTypes) addObject: cType];
    }
}
/**
 * Name:        loadTemplate:(NSURL*)(NSError**)
 * Parameters:  (NSURL*) The specified template URL (location) as to where we are basing our simple types on and code to generate
 *              (NSError**) Associated error object pointer
 * Return:      BOOL - YES or NO if there was an error
 * Description: For each simple type that is defined in our template, fetch the associated elements
 *              that is within our XSD simpleTypes. Add the associated code that is defined within
 *              the template that will be used when we generate code for the complex types.
 *              Also define the header files
 */

- (BOOL) loadTemplate:(NSURL*)templateUrl error:(NSError**)error {
    NSParameterAssert(templateUrl);
    NSParameterAssert(error);
    /* Load the template xml document */
    NSXMLDocument* xmlDoc = [[NSXMLDocument alloc] initWithContentsOfURL: templateUrl
                                                                 options:(NSXMLNodePreserveWhitespace|NSXMLNodePreserveCDATA)
                                                                   error: error];
    /* Ensure that there wasn't errors */
    if(*error != nil) {
        return NO;
    }

    /* Check for additional file notes off of the template. */
    NSArray* additionalFileNodes = [xmlDoc nodesForXPath:@"/template[1]/additional_file" error: error];
    if(*error != nil) {
        return NO;
    }
    
    /* Fetch the additional filter defined in the additionfield fields above */
    NSMutableArray *mAdditionalFiles = [NSMutableArray arrayWithCapacity:additionalFileNodes.count];
    NSMutableDictionary *mAdditionalFiles = [NSMutableDictionary dictionaryWithCapacity:additionalFileNodes.count];
    for(NSXMLElement* fileNode in additionalFileNodes) {
        NSString *path = [[[NSBundle bundleForClass:[XSDschema class]] resourcePath] stringByAppendingPathComponent:[fileNode attributeForName:@"path"].stringValue];
        if(![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            path = [fileNode attributeForName:@"path"].stringValue;
            if(![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                path = nil;
            }
        }
        
        if(path) {
            NSString *targetPath = [fileNode attributeForName:@"target_path"].stringValue;
            
            [mAdditionalFiles setObject:targetPath?targetPath:path forKey:path];
        }
    }
    /* If we have additonal files, add them to the schema */
    if(mAdditionalFiles.count) {
        self.additionalFiles = [NSDictionary dictionaryWithDictionary:mAdditionalFiles];
    }
    
    /* From the template, grab all the simple type elements and ensure that there wasn't an error */

    //
    //formatter style
    //
    NSArray* styleNodes = [xmlDoc nodesForXPath:@"/template[1]/format_style" error: error];
    if(*error != nil) {
        return NO;
    }
    for(NSXMLElement* styleNode in styleNodes) {
        NSString *value = [styleNode stringValue];
        if(value.length) {
            if([value isEqualToString:@"objc"]) {
                self.formatter = [DDUncrustifyFormatter objectiveCFormatter];
            }
            else if([value isEqualToString:@"swift"]) {
                self.formatter = [DDUncrustifyFormatter swiftFormatter];
            }
            else if([[NSFileManager defaultManager] fileExistsAtPath:value]) {
                self.formatter = [[DDUncrustifyFormatter alloc] initWithStylePath:value];
            }
        }
        break;
    }

    //
    //reading simple types and merging them with our known ones
    //
    NSArray* simpleTypeNodes = [xmlDoc nodesForXPath:@"/template[1]/simpletype" error: error];
    if(*error != nil) {
        return NO;
    }
    
    /* Iterate through the simple types found within the template */
    for(NSXMLElement* aSimpleTypeNode in simpleTypeNodes) {
        /* Build the node for the element found in the template */
        XSSimpleType* aSimpleType = [[XSSimpleType alloc] initWithNode:aSimpleTypeNode schema:self];
        
        /* For the name of the node found, check if we have that item created in our known types of the XSD*/
        XSSimpleType *existingSimpleType = _knownSimpleTypeDict[aSimpleType.name];
        
        /* Check if we have that simpletype within our XSD provided */
        if(existingSimpleType) {
            /* For our simple type, define the values from the template */
            [existingSimpleType supplyTemplates:aSimpleTypeNode error:error];
        }
        else {
            [aSimpleType  supplyTemplates:aSimpleTypeNode error:error];
            [_knownSimpleTypeDict setValue: aSimpleType forKey: aSimpleType.name];
        }
    }
    
    /* Fetch the header file that we will use in the implementation section */
    NSArray* nodes = [xmlDoc nodesForXPath:@"/template[1]/implementation[1]/header" error: error];
    if(*error != nil) {
        return NO;
    }
    /* Assign the header file text from the fetched section */
    if(nodes != nil && nodes.count > 0) {
        self.headerTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.headerTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
    
    
    /* Fetch the class file that we will use in the implementation section */
    nodes = [xmlDoc nodesForXPath:@"/template[1]/implementation[1]/class" error: error];
    if(*error != nil) {
        return NO;
    }
    /* Assign the class file text from the fetched section */
    if(nodes != nil && nodes.count > 0) {
        self.classTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.classTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
    
    /* Fetch the... */
    nodes = [xmlDoc nodesForXPath:@"/template[1]/complextype[1]/read[1]/element[1]" error: error];
    if(*error != nil) {
        return NO;
    }
    /* Assign the text from the fetched section */
    if(nodes != nil && nodes.count > 0) {
        self.readComplexTypeElementTemplate = [[nodes objectAtIndex: 0] stringValue];
    }
    
    nodes = [xmlDoc nodesForXPath:@"/template[1]/complextype[1]" error: error];
    if(*error != nil) {
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.complexTypeArrayType = [[nodes objectAtIndex: 0] attributeForName:@"arrayType"].stringValue;
    }
    
    nodes = [xmlDoc nodesForXPath:@"/template[1]/reader[1]/header" error: error];
    if(*error != nil) {
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.readerHeaderTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.readerHeaderTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
    
    nodes = [xmlDoc nodesForXPath:@"/template[1]/reader[1]/class" error: error];
    if(*error != nil) {
        return NO;
    }
    if(nodes != nil && nodes.count > 0) {
        self.readerClassTemplateString = [[nodes objectAtIndex: 0] stringValue];
        self.readerClassTemplateExtension = [XMLUtils node:[nodes objectAtIndex: 0] stringAttribute:@"extension"];
    }
 
    //
    //load included schemes
    //
    for (XSDschema *s in self.includedSchemas) {
        BOOL br = [s loadTemplate:templateUrl error:error];
        if(!br) {
            return NO;
        }
    }
    return YES;
}

- (id<XSType>) typeForName: (NSString*) qName {
    if(self.parentSchema) {
        /* Defer */
        return [self.parentSchema typeForName:qName];
    }
    
    NSParameterAssert(qName.length); //EVERYTHING has a type name
    
    NSString* typeName = qName;
    NSArray* splitPrefix = [qName componentsSeparatedByCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @":"]];
    
    if(splitPrefix.count > 1) {
        typeName = (NSString*) [splitPrefix objectAtIndex: 1];
    }
    
    /* Search the complexType dictionary for the type name */
    id<XSType> retType = [_knownComplexTypeDict objectForKey:typeName];
    
    /* Search the simpleType dictionary for the type name */
    if(!retType) {
        retType = [_knownSimpleTypeDict objectForKey:typeName];
    }
    
    assert(retType); //EVERYTHING has to have a type
    return retType;
}

- (NSString*)classPrefixForType:(id<XSType>)type {
    if(self.parentSchema) {
        //defer
        return [self.parentSchema classPrefixForType:type];
    }

    NSString *qName = [type name];

    NSParameterAssert(qName.length); //EVERYTHING has a type name
    
    NSArray* splitPrefix = [qName componentsSeparatedByCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @":"]];
    
    NSString *namespace;
    if(splitPrefix.count > 1) {
        namespace = (NSString*) [splitPrefix objectAtIndex: 0];
    }
    
    if(!namespace || [namespace isEqualTo:self.targetNamespace]) {
        return self.targetNamespacePrefix;
    }
    else {
        return [self.targetNamespacePrefix stringByAppendingString:namespace.capitalizedString];
    }
}

+ (NSString*) variableNameFromName:(NSString*)vName multiple:(BOOL)multiple {
    NSParameterAssert(vName.length);
    
    NSCharacterSet* illegalChars = [NSCharacterSet characterSetWithCharactersInString: @"-"];
    NSRange range = [vName rangeOfCharacterFromSet: illegalChars];
    while(range.length > 0) {
        vName = [vName stringByReplacingCharactersInRange: range withString: @""];
        // range is now at next char
        vName = [vName stringByReplacingCharactersInRange: range withString:[[vName substringWithRange: range] uppercaseString]];
        
        range = [vName rangeOfCharacterFromSet: illegalChars];
    }
    
    //grammar fix
    if(multiple) {
        if(![vName hasSuffix:@"s"])
        {
            if([vName hasSuffix:@"y"]) {
                vName = [vName substringToIndex:vName.length-1];
                vName = [vName stringByAppendingString:@"ies"];
            }
            else {
                vName = [vName stringByAppendingString:@"s"];
            }
        }
    }
    
    //name fixes
    id newName = [[self.class knownNameChanges] objectForKey:vName];
    if(newName) {
        vName = newName;
    }
    
    assert(vName.length); //EVERYTHING has a name
    return vName;
}

#pragma mark

+ (NSDictionary *)knownNameChanges {
    static NSDictionary* knownNameChanges;
    if(!knownNameChanges) {
        NSURL *url = [[NSBundle bundleForClass:[self class]] URLForResource:@"nameChanges" withExtension:@"xml"];
        NSData* data = [NSData dataWithContentsOfURL: url];
        NSXMLDocument* doc = [[NSXMLDocument alloc] initWithData: data options: 0 error: nil];
        if(!doc) {
            return nil;
        }
        
        NSArray* iNodes = [[doc rootElement] nodesForXPath: @"/nameChanges/nameChange" error: nil];
//        if(!iNodes) {
//            return nil;
//        }
        
        knownNameChanges  = [NSMutableDictionary dictionaryWithCapacity:iNodes.count];
        for (NSXMLElement *element in iNodes) {
            id from = [XMLUtils node:element stringAttribute:@"from"];
            id to = [XMLUtils node:element stringAttribute:@"to"];
            [(NSMutableDictionary*)knownNameChanges setObject:to forKey:from];             
        }
    }
    return knownNameChanges;
}

#pragma mark - generator
/**
 * Name:        generateInto (NSURL*)(XSDschemaGeneratorOptions)(NSError**)
 * Parameters:  (NSURL*)destinationFolder - the location where we will be writing the documents to
 *              (XSDschemaGeneratorOptions) - the options that the user selected and the type of code to write
 *              (NSError**) - error pointing object
 * Return:      BOOL - YES or NO if there was an error
 * Description: Will generate the code for the complex types that are used within the schema into objective-c
 *              by using the templates for the simple types (loadTemplates). This will render the template code
 *              and insert the proper values into the template space. Will return if there is an error
 */
- (BOOL) generateInto:(NSURL*)destinationFolder
             products:(XSDschemaGeneratorOptions)options
                error:(NSError**)error {
    NSParameterAssert(destinationFolder);
    NSParameterAssert(error);
    
    /* SOURCE CODE - If we want to write source code */
    if (options & XSDschemaGeneratorOptionSourceCode) {
        /* Create the path that will contain all the code */
        NSURL *srcFolderUrl = [destinationFolder URLByAppendingPathComponent:@"Sources" isDirectory:YES];
        
        /* Create the actual directory at the location defined above */
        if(![[NSFileManager defaultManager] createDirectoryAtURL:srcFolderUrl withIntermediateDirectories:NO attributes:nil error:error]) {
            BOOL isDir;
            /* Ensure that the item was created */
            if(![[NSFileManager defaultManager] fileExistsAtPath:srcFolderUrl.path isDirectory:&isDir] || !isDir) {
                return NO;
            }
        }
        /* If all is well, start writing the code into the directory we created */
        if(![self writeCodeInto:srcFolderUrl error:error]) {
            return NO;
        }
        if(![self formatFilesInFolder:srcFolderUrl error:nil])  {
    }

    /* FRAMEWORK - If we want to write a framework */
    if (options & XSDschemaGeneratorOptionDynamicFramework) {
        NSURL *productsFolderUrl = [destinationFolder URLByAppendingPathComponent:@"Products" isDirectory:YES];
        NSURL *osxFolderUrl = [productsFolderUrl URLByAppendingPathComponent:@"OSX" isDirectory:YES];
        
        if(![[NSFileManager defaultManager] createDirectoryAtURL:osxFolderUrl withIntermediateDirectories:YES attributes:nil error:error]) {
            BOOL isDir;
            if(![[NSFileManager defaultManager] fileExistsAtPath:osxFolderUrl.path isDirectory:&isDir] || !isDir) {
                return NO;
            }
        }
        
        if(![self writeFrameworkTo:osxFolderUrl error:error]) {
            return NO;
        }
    }

//    NSURL *productsFolderUrl = [destinationFolder URLByAppendingPathComponent:@"Products" isDirectory:YES];

//    //write Framework
//    if (options & XSDschemaGeneratorOptionDynamicFramework) {
//        NSURL *osxFolderUrl = [productsFolderUrl URLByAppendingPathComponent:@"OSX" isDirectory:YES];
//        
//        if(![[NSFileManager defaultManager] createDirectoryAtURL:osxFolderUrl withIntermediateDirectories:YES attributes:nil error:error]) {
//            BOOL isDir;
//            if(![[NSFileManager defaultManager] fileExistsAtPath:osxFolderUrl.path isDirectory:&isDir] || !isDir) {
//                return NO;
//            }
//        }
//        
//        if(![self writeDynamicOSXFrameworkTo:osxFolderUrl error:error]) {
//            return NO;
//        }
//
//        NSURL *iosFolderUrl = [productsFolderUrl URLByAppendingPathComponent:@"IOS" isDirectory:YES];
//        
//        if(![[NSFileManager defaultManager] createDirectoryAtURL:iosFolderUrl withIntermediateDirectories:YES attributes:nil error:error]) {
//            BOOL isDir;
//            if(![[NSFileManager defaultManager] fileExistsAtPath:iosFolderUrl.path isDirectory:&isDir] || !isDir) {
//                return NO;
//            }
//        }
//        
//        if(![self writeIOSModuleTo:iosFolderUrl error:error]) {
//            return NO;
//        }
//    }
//
//    //write cross-platform static lib
//    if (options & XSDschemaGeneratorOptionStaticFramework) {
//        NSURL *bothFolderUrl = [productsFolderUrl URLByAppendingPathComponent:@"BOTH" isDirectory:YES];
//        
//        if(![[NSFileManager defaultManager] createDirectoryAtURL:bothFolderUrl withIntermediateDirectories:YES attributes:nil error:error]) {
//            BOOL isDir;
//            if(![[NSFileManager defaultManager] fileExistsAtPath:bothFolderUrl.path isDirectory:&isDir] || !isDir) {
//                return NO;
//            }
//        }
//        
//        if(![self writeStaticFrameworkTo:bothFolderUrl error:error]) {
//            return NO;
//        }
//    }

    return YES;
}

/**
 * Name:        writeCodeInto (NSURL*)(NSError**)
 * Parameters:  (NSURL*)destinationFolder - the location where we will be writing the documents to
 *              (NSError**) - error pointing object
 * Return:      BOOL - YES or NO if there was an error
 * Description: Will consume the complex types
 *
 */
- (BOOL) writeCodeInto: (NSURL*) destinationFolder
                 error: (NSError**) error {
    *error = nil;
    
    /* If there is no template, return that is failed */
    if(!self.complexTypeArrayType) {
        return NO;
    }

    //copy additional files
    [self.additionalFiles enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSString *srcPath = key;
        NSString *destPath = [destinationFolder.path stringByAppendingPathComponent:obj];
        [[NSFileManager defaultManager] copyItemAtPath:srcPath toPath:destPath error:nil];
    }];

    // Set up template engine with your chosen matcher.
    MGTemplateEngine *engine = [MGTemplateEngine templateEngine];
    [engine setMatcher:[ICUTemplateMatcher matcherWithTemplateEngine:engine]];
    
    /* Start writing our classes for the complex types */
    for(XSDcomplexType* type in self.complexTypes) {
        /* Create the items for the header file */
        if (self.headerTemplateString != nil) {
            /* Generate the code from the template and from the variables */
            NSString *result = [engine processTemplate:self.headerTemplateString
                                         withVariables:type.substitutionDict];
            
            NSString* headerFileName = [NSString stringWithFormat: @"%@.%@", type.targetClassFileName, self.headerTemplateExtension];
            NSURL* headerFilePath = [destinationFolder URLByAppendingPathComponent: headerFileName];
            [result writeToURL: headerFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];

            /* Ensure that there was no errors for writing */
            if(*error != nil) {
                return NO;
            }
        }
        
        /* Create the items for the class file */
        if (self.classTemplateString != nil) {
            /* Generate the code from the template and the variables */
            NSString *result = [engine processTemplate: self.classTemplateString
                                         withVariables: type.substitutionDict];
            
            NSString* classFileName = [NSString stringWithFormat: @"%@.%@", type.targetClassFileName, self.classTemplateExtension];
            NSURL* classFilePath = [destinationFolder URLByAppendingPathComponent: classFileName];
            [result writeToURL:classFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];
            
            /* Ensure that there was no errors for writing */
            if(*error != nil) {
                return NO;
            }
        }
        
        /* Create the files for the global elements */
        if(type.globalElements.count) {
            if (self.readerHeaderTemplateString.length) {
                NSString *result = [engine processTemplate: self.readerHeaderTemplateString
                                             withVariables: type.substitutionDict];
                
                NSString* headerFileName = [NSString stringWithFormat: @"%@+File.%@", type.targetClassFileName, self.readerHeaderTemplateExtension];
                NSURL* headerFilePath = [destinationFolder URLByAppendingPathComponent: headerFileName];
                [result writeToURL: headerFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];

                /* Ensure that there was no errors for writing */
                if(*error != nil) {
                    return NO;
                }
            }
            
            if (self.readerClassTemplateString.length) {
                NSString *result = [engine processTemplate: self.readerClassTemplateString
                                             withVariables: type.substitutionDict];
                
                NSString* classFileName = [NSString stringWithFormat: @"%@+File.%@", type.targetClassFileName, self.readerClassTemplateExtension];
                NSURL* classFilePath = [destinationFolder URLByAppendingPathComponent: classFileName];
                [result writeToURL: classFilePath atomically:YES encoding: NSUTF8StringEncoding error: error];
                
                /* Ensure that there was no errors for writing */
                if(*error != nil) {
                    return NO;
                }
            }
        }
    }
    
    //umbrella header - objC hack
    if([self.headerTemplateExtension isEqualToString:@"h"]) {
        //add header
        NSString *fileName = [NSString stringWithFormat:@"%@.h", self.schemaUrl.lastPathComponent.stringByDeletingPathExtension];
        NSURL *filePath = [destinationFolder URLByAppendingPathComponent:fileName];
    
        //add includes for all other files
        NSString *includes = [self contentOfObjcUmbrellaHeaderForFolder:destinationFolder];
        BOOL br = [includes writeToURL:filePath atomically:YES encoding:NSUTF8StringEncoding error:error];
        if(!br) {
            return NO;
        }
    }
    
    return YES;
}

- (NSString*)contentOfObjcUmbrellaHeaderForFolder:(NSURL*)destinationFolder {
    NSParameterAssert(destinationFolder);
    
    NSDirectoryEnumerator *dirEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:destinationFolder
                                                                includingPropertiesForKeys:@[ NSURLNameKey, NSURLIsDirectoryKey ]
                                                                                   options:NSDirectoryEnumerationSkipsPackageDescendants| NSDirectoryEnumerationSkipsHiddenFiles
                                                                              errorHandler:nil];

    NSMutableString *includes = [NSMutableString string];
    for (NSURL *theURL in dirEnumerator) {
        NSNumber *isDirectory;
        [theURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if (![isDirectory boolValue]) {
            if([theURL.pathExtension isEqualTo:@"h"]) {
                if(includes.length) {
                    [includes appendString:@"\n"];
                }
                [includes appendFormat:@"#import \"%@\"", theURL.lastPathComponent];
            }
        }
    }
    
    return includes;
}

- (BOOL) formatFilesInFolder: (NSURL*) destinationFolder
                       error: (NSError**) error {
    //CAN BE SKIPPED
    if(!self.formatter) return YES;
    
    NSParameterAssert(destinationFolder);
    
    NSDirectoryEnumerator *dirEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:destinationFolder
                                                                includingPropertiesForKeys:@[ NSURLNameKey, NSURLIsDirectoryKey ]
                                                                                   options:NSDirectoryEnumerationSkipsPackageDescendants| NSDirectoryEnumerationSkipsHiddenFiles
                                                                              errorHandler:nil];
    
    NSMutableArray *files = [NSMutableArray array];
    for (NSURL *theURL in dirEnumerator) {
        NSNumber *isDirectory;
        [theURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if (![isDirectory boolValue]) {
            [files addObject:theURL.path];
        }
    }

    NSArray *formatted = [self.formatter formatFiles:files error:error];
    
    return (formatted.count == files.count);
}

//#pragma mark -
//
//- (BOOL)writeDynamicOSXFrameworkTo:(NSURL*)destinationFolder error:(NSError**)error {
//    NSURL *tmpFolderUrl = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
//    
//    if(![[NSFileManager defaultManager] createDirectoryAtURL:tmpFolderUrl withIntermediateDirectories:NO attributes:nil error:error]) {
//        return NO;
//    }
//    if(![self writeCodeInto:tmpFolderUrl error:error]) {
//        return NO;
//    }
//    if(![self formatFilesInFolder:tmpFolderUrl error:nil])  {
//        return NO;
//    }
//    
//    //compile it
//    NSMutableArray *libraries = [NSMutableArray array];
//    
//    id files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:tmpFolderUrl includingPropertiesForKeys:nil options:0 error:nil];
//
//    id flags = @[@"-dead_strip", @"-fobjc-arc", @"-ObjC", @"-dynamiclib", @"-arch", @"x86_64", @"-framework", @"foundation", @"-lxml2", @"-I/usr/include/libxml2"];
//    NSURL *targetPath = [destinationFolder URLByAppendingPathComponent:@"x86_64.dylib"];
//    if(![[DDFrameworkWriter sharedWriter] createDynamicLibAt:targetPath.path
//                                                  inputFiles:files
//                                             additionalFlags:flags
//                                                       error:error]) {
//        return NO;
//    }
//    [libraries addObject:targetPath];
//    
//    
//     id name = self.schemaUrl.lastPathComponent.stringByDeletingPathExtension;
//     id bid = [[[NSBundle mainBundle] bundleIdentifier] stringByAppendingFormat:@".%@-parser", name];
//     NSArray *headers = [[files valueForKeyPath:@"path"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF endswith %@", @".h"]];
//     
//     //compile it and make it a framework
//     if(![[DDFrameworkWriter sharedWriter] writeFrameworkWithIdentifier:bid
//                                                                andName:name
//                                                                 atPath:tmpFolderUrl.path
//                                                              libraries:libraries
//                                                                headers:headers
//                                                          resourceFiles:nil
//                                                                  error:error]) {
//        return NO;
//    }
//     
//     NSURL *frameworkSrc = [[tmpFolderUrl URLByAppendingPathComponent:name] URLByAppendingPathExtension:@"framework"];
//     
//     NSURL *frameworkDest = [[destinationFolder URLByAppendingPathComponent:name] URLByAppendingPathExtension:@"framework"];
//     
//     if([[NSFileManager defaultManager] fileExistsAtPath:frameworkDest.path]) {
//         if(![[NSFileManager defaultManager] removeItemAtURL:frameworkDest error:error]) {
//             return NO;
//         }
//         
//     }
//     if(![[NSFileManager defaultManager] copyItemAtURL:frameworkSrc toURL:frameworkDest error:error]) {
//         return NO;
//     }
//     
//     return [[NSFileManager defaultManager] removeItemAtURL:tmpFolderUrl error:error];
//}
//
//- (BOOL)writeIOSModuleTo:(NSURL*)destinationFolder error:(NSError**)error {
//    NSURL *tmpFolderUrl = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
//    
//    if(![[NSFileManager defaultManager] createDirectoryAtURL:tmpFolderUrl withIntermediateDirectories:NO attributes:nil error:error]) {
//        return NO;
//    }
//    if(![self writeCodeInto:tmpFolderUrl error:error]) {
//        return NO;
//    }
//    if(![self formatFilesInFolder:tmpFolderUrl error:nil])  {
//        return NO;
//    }
//    
//    //compile it
//    NSMutableArray *libraries = [NSMutableArray array];
//    
//    id files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:tmpFolderUrl includingPropertiesForKeys:nil options:0 error:nil];
//    id flags = @[@"-dead_strip", @"-fobjc-arc", @"-ObjC", @"-dynamiclib", @"-arch", @"arm64", @"-framework", @"foundation", @"-lxml2", @"-I/usr/include/libxml2", @"-isysroot", @"/Applications/Xcode-Beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS8.2.sdk"];
//    NSURL *targetPath = [destinationFolder URLByAppendingPathComponent:@"arm64.dylib"];
//    if(![[DDFrameworkWriter sharedWriter] createDynamicLibAt:targetPath.path
//                                                  inputFiles:files
//                                             additionalFlags:flags
//                                                       error:error]) {
//        return NO;
//    }
//    [libraries addObject:targetPath];
//
//    flags = @[@"-dead_strip", @"-fobjc-arc", @"-ObjC", @"-dynamiclib", @"-arch", @"armv7", @"-framework", @"foundation", @"-lxml2", @"-I/usr/include/libxml2", @"-isysroot", @"/Applications/Xcode-Beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS8.2.sdk"];
//    targetPath = [destinationFolder URLByAppendingPathComponent:@"armv7.dylib"];
//    if(![[DDFrameworkWriter sharedWriter] createDynamicLibAt:targetPath.path
//                                                  inputFiles:files
//                                             additionalFlags:flags
//                                                       error:error]) {
//        return NO;
//    }
//    [libraries addObject:targetPath];
//
//    //compile it and make it a module
//    id name = self.schemaUrl.lastPathComponent.stringByDeletingPathExtension;
//    id bid = [[[NSBundle mainBundle] bundleIdentifier] stringByAppendingFormat:@".%@-parser", name];
//    NSArray *headers = [[files valueForKeyPath:@"path"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF endswith %@", @".h"]];
//    
//    if(![[DDFrameworkWriter sharedWriter] writeModuleWithIdentifier:bid
//                                                            andName:name
//                                                             atPath:tmpFolderUrl.path
//                                                          libraries:libraries
//                                                            headers:headers
//                                                      resourceFiles:nil
//                                                                 error:error]) {
//        return NO;
//    }
//    
//    NSURL *frameworkSrc = [[tmpFolderUrl URLByAppendingPathComponent:name] URLByAppendingPathExtension:@"framework"];
//    
//    NSURL *frameworkDest = [[destinationFolder URLByAppendingPathComponent:name] URLByAppendingPathExtension:@"framework"];
//    
//    if([[NSFileManager defaultManager] fileExistsAtPath:frameworkDest.path]) {
//        if(![[NSFileManager defaultManager] removeItemAtURL:frameworkDest error:error]) {
//            return NO;
//        }
//        
//    }
//    if(![[NSFileManager defaultManager] copyItemAtURL:frameworkSrc toURL:frameworkDest error:error]) {
//        return NO;
//    }
//    
//    return [[NSFileManager defaultManager] removeItemAtURL:tmpFolderUrl error:error];
//}
//
//- (BOOL)writeStaticFrameworkTo:(NSURL*)destinationFolder error:(NSError**)error {
//    NSURL *tmpFolderUrl = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
//    
//    if(![[NSFileManager defaultManager] createDirectoryAtURL:tmpFolderUrl withIntermediateDirectories:NO attributes:nil error:error]) {
//        return NO;
//    }
//    if(![self writeCodeInto:tmpFolderUrl error:error]) {
//        return NO;
//    }
//    if(![self formatFilesInFolder:tmpFolderUrl error:nil])  {
//        return NO;
//    }
//    
//    //compile it
//    NSMutableArray *libraries = [NSMutableArray array];
//    
//    id flags = @[@"-dead_strip", @"-fobjc-arc", @"-ObjC", @"-staticlib", @"-arch", @"x86_64", @"-framework", @"foundation", @"-lxml2", @"-I/usr/include/libxml2"];
//    NSURL *targetPath = [destinationFolder URLByAppendingPathComponent:@"x86_64.a"];
//    id files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:tmpFolderUrl includingPropertiesForKeys:nil options:0 error:nil];
//    if(![[DDFrameworkWriter sharedWriter] createStaticLibAt:targetPath.path
//                                                 inputFiles:files
//                                            additionalFlags:flags
//                                                      error:error]) {
//        return NO;
//    }
//    [libraries addObject:targetPath];
//
//    flags = @[@"-dead_strip", @"-fobjc-arc", @"-ObjC", @"-staticlib", @"-arch", @"arm64", @"-framework", @"foundation", @"-lxml2", @"-I/usr/include/libxml2", @"-isysroot", @"/Applications/Xcode-Beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS8.2.sdk"];
//    targetPath = [destinationFolder URLByAppendingPathComponent:@"arm64.dylib"];
//    if(![[DDFrameworkWriter sharedWriter] createStaticLibAt:targetPath.path
//                                                 inputFiles:files
//                                            additionalFlags:flags
//                                                      error:error]) {
//        return NO;
//    }
//    [libraries addObject:targetPath];
//    
//    flags = @[@"-dead_strip", @"-fobjc-arc", @"-ObjC", @"-staticlib", @"-arch", @"armv7", @"-framework", @"foundation", @"-lxml2", @"-I/usr/include/libxml2", @"-isysroot", @"/Applications/Xcode-Beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS8.2.sdk"];
//    targetPath = [destinationFolder URLByAppendingPathComponent:@"arm64.dylib"];
//    if(![[DDFrameworkWriter sharedWriter] createStaticLibAt:targetPath.path
//                                                 inputFiles:files
//                                            additionalFlags:flags
//                                                      error:error]) {
//        return NO;
//    }
//    [libraries addObject:targetPath];
//    
//    id name = self.schemaUrl.lastPathComponent.stringByDeletingPathExtension;
//    id bid = [[[NSBundle mainBundle] bundleIdentifier] stringByAppendingFormat:@".%@-parser", name];
//    NSArray *headers = [[files valueForKeyPath:@"path"] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF endswith %@", @".h"]];
//    
//    //compile it and make it a framework
//    if(![[DDFrameworkWriter sharedWriter] writeFrameworkWithIdentifier:bid
//                                                               andName:name
//                                                                atPath:tmpFolderUrl.path
//                                                            libraries:libraries
//                                                               headers:headers
//                                                         resourceFiles:nil
//                                                                 error:error]) {
//        return NO;
//    }
//    
//    NSURL *frameworkSrc = [[tmpFolderUrl URLByAppendingPathComponent:name] URLByAppendingPathExtension:@"framework"];
//    
//    NSURL *frameworkDest = [[destinationFolder URLByAppendingPathComponent:name] URLByAppendingPathExtension:@"framework"];
//    
//    if([[NSFileManager defaultManager] fileExistsAtPath:frameworkDest.path]) {
//        if(![[NSFileManager defaultManager] removeItemAtURL:frameworkDest error:error]) {
//            return NO;
//        }
//        
//    }
//    if(![[NSFileManager defaultManager] copyItemAtURL:frameworkSrc toURL:frameworkDest error:error]) {
//        return NO;
//    }
//    
//    return [[NSFileManager defaultManager] removeItemAtURL:tmpFolderUrl error:error];
//}

@end
