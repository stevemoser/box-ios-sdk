//
//  BOXClient.m
//  BoxContentSDK
//
//  Created by Scott Liu on 11/4/14.
//  Copyright (c) 2014 Box. All rights reserved.
//

#import "BOXContentClient_Private.h"
#import "BOXContentClient+Authentication.h"
#import "BOXAPIQueueManager.h"
#import "BOXContentSDKConstants.h"
#import "BOXParallelOAuth2Session.h"
#import "BOXParallelAPIQueueManager.h"
#import "BOXUser.h"
#import "BOXRequestWithSharedLinkHeader.h"
#import "BOXSharedItemRequest.h"
#import "BOXSharedLinkHeadersHelper.h"
#import "BOXSharedLinkHeadersDefaultManager.h"
#import "BOXContentSDKErrors.h"

@interface BOXContentClient ()

@property (nonatomic, readwrite, strong) BOXSharedLinkHeadersHelper *sharedLinksHeaderHelper;
+ (void)resetInstancesForTesting;
@end

@implementation BOXContentClient

@synthesize APIBaseURL = _APIBaseURL;
@synthesize OAuth2Session = _OAuth2Session;
@synthesize appSession = _appSession;
@synthesize queueManager = _queueManager;

static NSString *staticClientID;
static NSString *staticClientSecret;
static BOOL staticAppToAppBoxAuthenticationEnabled = NO;
static NSMutableDictionary *_SDKClients;
static dispatch_once_t onceTokenForDefaultClient = 0;
static BOXContentClient *defaultInstance = nil;

+ (BOXContentClient *)defaultClient
{
    dispatch_once(&onceTokenForDefaultClient, ^{
        if (defaultInstance == nil) {
            NSArray *storedUsers = [self users];
            if (storedUsers.count > 1)
            {
                [NSException raise:@"You cannot use 'defaultClient' if multiple users have established a session."
                            format:@"Specify a user through clientForUser:"];
            }
            else if (storedUsers.count == 1)
            {
                BOXUserMini *storedUser = [storedUsers firstObject];
                defaultInstance = [[[self class] SDKClients] objectForKey:storedUser.modelID];
                if (defaultInstance == nil) {
                    defaultInstance = [[self alloc] initWithBOXUser:storedUser];
                    [[[self class] SDKClients] setObject:defaultInstance forKey:storedUser.modelID];
                }
            }
            else
            {
                defaultInstance = [[self alloc] init];
            }
        }
    });
    return defaultInstance;
}

+ (BOXContentClient *)clientForUser:(BOXUserMini *)user
{
    if (user == nil)
    {
        return [self clientForNewSession];
    }
    
    static NSString *synchronizer = @"synchronizer";
    @synchronized(synchronizer)
    {
        BOXContentClient *client = [[[self class] SDKClients] objectForKey:user.modelID];
        if (client == nil) {
            // Only OAuth2Session contain a refresh token. Otherwise it's an AppUserSession.
            client = [[self alloc] initWithBOXUser:user];
            
            [[[self class] SDKClients] setObject:client forKey:user.modelID];
        }
        
        return client;
    }
}

+ (BOXContentClient *)clientForNewSession
{
    return [[self alloc] init];
}

+ (void)setClientID:(NSString *)clientID clientSecret:(NSString *)clientSecret
{
    if (clientID.length == 0) {
        [NSException raise:@"Invalid client ID." format:@"%@ is not a valid client ID", clientID];
        return;
    }
    if (clientSecret.length == 0) {
        [NSException raise:@"Invalid client secret." format:@"%@ is not a valid client secret", clientSecret];
        return;
    }
    if (staticClientID.length > 0 && ![staticClientID isEqualToString:clientID]) {
        [NSException raise:@"Changing the client ID is not allowed." format:@"Cannot change client ID from %@ to %@", staticClientID, clientID];
        return;
    }
    if (staticClientSecret.length > 0 && ![staticClientSecret isEqualToString:clientSecret]) {
        [NSException raise:@"Changing the client secret is not allowed." format:@"Cannot change client secret from %@ to %@", staticClientSecret, clientSecret];
        return;
    }
    
    staticClientID = clientID;
    staticClientSecret = clientSecret;
}

+ (void)setAppToAppBoxAuthenticationEnabled:(BOOL)enabled
{
    staticAppToAppBoxAuthenticationEnabled = enabled;
}

- (instancetype)init
{
    if (self = [super init])
    {
        if (staticClientID.length == 0 || staticClientSecret.length == 0) {
            [NSException raise:@"Set client ID and client secret first." format:@"You must set a client ID and client secret first."];
            return nil;
        }
        
        [self setAPIBaseURL:BOXAPIBaseURL];
        
        // the circular reference between the queue manager and the session is necessary
        // because sessions enqueue API operations to fetch access tokens and the queue
        // manager uses the session as a lock object when enqueuing operations.
        _queueManager = [[BOXParallelAPIQueueManager alloc] init];

        _OAuth2Session = [[BOXParallelOAuth2Session alloc] initWithClientID:staticClientID
                                                                         secret:staticClientSecret
                                                                     APIBaseURL:BOXAPIBaseURL//FIXME:
                                                                   queueManager:_queueManager];
        _queueManager.session = self.session;
        
        
        // Initialize our sharedlink helper with the default protocol implementation
        _sharedLinksHeaderHelper = [[BOXSharedLinkHeadersHelper alloc] initWithClient:self];
        [self setSharedLinkStorageDelegate:[[BOXSharedLinkHeadersDefaultManager alloc] init]];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveSessionDidBecomeAuthenticatedNotification:)
                                                     name:BOXSessionDidBecomeAuthenticatedNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveSessionWasRevokedNotification:)
                                                     name:BOXSessionWasRevokedNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveUserWasLoggedOutNotification:)
                                                     name:BOXUserWasLoggedOutDueToErrorNotification
                                                   object:nil];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveAccessTokenRefreshedNotification:)
                                                     name:BOXSessionDidRefreshTokensNotification
                                                   object:nil];
    }
    return self;
}

- (instancetype)initWithBOXUser:(BOXUserMini *)user
{
    if (self = [self init])
    {
        BOXOAuth2Session *session = [[BOXOAuth2Session alloc]init];
        [session restoreCredentialsFromKeychainForUserWithID:user.modelID];
        
        if (session.refreshToken == nil) {
            self.session = [[BOXAppUserSession alloc]initWithAPIBaseURL:self.APIBaseURL queueManager:self.queueManager];
        }
        
        [self.session restoreCredentialsFromKeychainForUserWithID:user.modelID];
    }
    return self;
}

- (void)didReceiveAccessTokenRefreshedNotification:(NSNotification *)notification
{
    BOXAbstractSession *session = (BOXAbstractSession *)notification.object;
    if (self.user.modelID && session.user.modelID && ![self.user.modelID isEqualToString:session.user.modelID]) {
        BOXAssertFail(@"BOXUser mismatch in BOXContentClient instance. Client User: %@, does not match Session User: %@", self.user.modelID, session.user.modelID);
    }
}

- (void)didReceiveUserWasLoggedOutNotification:(NSNotification *)notification
{
    NSDictionary *userInfo = (NSDictionary *)notification.object;
    NSString *userID = [userInfo objectForKey:BOXUserIDKey];
    if ([userID isEqualToString:self.user.modelID]) {
        [self logOut];
    }
}

- (void)didReceiveSessionDidBecomeAuthenticatedNotification:(NSNotification *)notification
{
    // We should never have more than one session pointing to the same user.
    // When a session becomes authenticated, any SDK clients that may have had a session for the same
    // user should update to the most recently authenticated one.
    BOXAbstractSession *session = (BOXAbstractSession *)notification.object;
    
    if ([session.user.modelID isEqualToString:self.session.user.modelID] && session != self.session) {
        // In case there are any pending operations in the old session's queue, give them the latest tokens so they have
        // a good chance of succeeding.
        [self.session reassignTokensFromSession:session];
        
        self.session = session;
        self.queueManager = self.session.queueManager;
    }
}

- (void)didReceiveSessionWasRevokedNotification:(NSNotification *)notification
{
    NSString *userIDRevoked = [notification.userInfo objectForKey:BOXUserIDKey];
    if (userIDRevoked.length > 0)
    {
        [[[self class] SDKClients] removeObjectForKey:userIDRevoked];
    }
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

+ (NSArray *)users
{
    return [BOXAbstractSession usersInKeychain];
}

- (BOXUserMini *)user
{
    return self.session.user;
}

- (BOOL)appToAppBoxAuthenticationEnabled
{
    return staticAppToAppBoxAuthenticationEnabled;
}

- (void)setAPIBaseURL:(NSString *)APIBaseURL
{
    _APIBaseURL = APIBaseURL;
    self.session.APIBaseURLString = APIBaseURL;
}

// Load the ressources bundle.
+ (NSBundle *)resourcesBundle
{
    static NSBundle *frameworkBundle = nil;
    static dispatch_once_t predicate;
    dispatch_once(&predicate, ^{
        NSURL *ressourcesBundleURL = [[NSBundle mainBundle] URLForResource:@"BoxContentSDKResources" withExtension:@"bundle"];
        frameworkBundle = [NSBundle bundleWithURL:ressourcesBundleURL];
    });

    return frameworkBundle;
}

- (void)setSharedLinkStorageDelegate:(id <BOXSharedLinkStorageProtocol>)delegate
{
    self.sharedLinksHeaderHelper.delegate = delegate;
}

- (BOXAbstractSession *)session
{
    if (self.OAuth2Session) {
        return self.OAuth2Session;
    } else {
        return self.appSession;
    }
}

- (void)setSession:(BOXAbstractSession *)session
{
    if ([session isKindOfClass:[BOXOAuth2Session class]]) {
        _OAuth2Session = (BOXOAuth2Session *)session;
        _appSession = nil;
    } else {
        _appSession = (BOXAppUserSession *)session;
        _OAuth2Session = nil;
    }
    self.queueManager.session = self.session;
}

#pragma mark - helper methods

- (void)prepareRequest:(BOXRequest *)request
{
    request.queueManager = self.queueManager;
    if ([request conformsToProtocol:@protocol(BOXSharedLinkItemSource)]) {
        BOXRequestWithSharedLinkHeader *requestWithSharedLink = (BOXRequestWithSharedLinkHeader *)request;
        requestWithSharedLink.sharedLinkHeadersHelper = self.sharedLinksHeaderHelper;
    } else if ([request isKindOfClass:[BOXSharedItemRequest class]]) {
        BOXSharedItemRequest *shareItemRequest = (BOXSharedItemRequest *)request;
        shareItemRequest.sharedLinkHeadersHelper = self.sharedLinksHeaderHelper;
    }
}


+ (NSMutableDictionary *)SDKClients
{
    if (_SDKClients == nil) {
        _SDKClients = [NSMutableDictionary dictionary];
    }
    return _SDKClients;
}

+ (void)resetInstancesForTesting
{
    defaultInstance = nil;
    onceTokenForDefaultClient = 0;
    [_SDKClients removeAllObjects];
}

@end
