//
//  AppBlade.m
//  AppBlade
//
//  Created by Craig Spitzkoff on 6/1/11.
//  Copyright 2011 AppBlade. All rights reserved.
//

#import "AppBlade.h"
#import "AppBladeSimpleKeychain.h"
#import "PLCrashReporter.h"
#import "PLCrashReport.h"
#import "AppBladeWebClient.h"
#import "PLCrashReportTextFormatter.h"
#import "FeedbackDialogue.h"
#import "asl.h"
#import <QuartzCore/QuartzCore.h>

static NSString* const s_sdkVersion                     = @"0.1";

const int kUpdateAlertTag                               = 316;

static NSString* const kAppBladeErrorDomain             = @"com.appblade.sdk";
static const int kAppBladeOfflineError                  = 1200;
static NSString *s_letters                              = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
static NSString* const kAppBladeCacheDirectory          = @"AppBladeCache";
static NSString* const kAppBladeFeedbackKeyConsole      = @"console";
static NSString* const kAppBladeFeedbackKeyNotes        = @"notes";
static NSString* const kAppBladeFeedbackKeyScreenshot   = @"screenshot";

@interface AppBlade () <AppBladeWebClientDelegate, FeedbackDialogueDelegate>

@property (nonatomic, retain) NSURL* upgradeLink;

// Feedback
@property (nonatomic, retain) NSMutableDictionary* feedbackDictionary;
@property (nonatomic, assign) BOOL showingFeedbackDialogue;
@property (nonatomic, retain) UITapGestureRecognizer* tapRecognizer;

- (void)raiseConfigurationExceptionWithFieldName:(NSString *)name;
- (void)handleCrashReport;
- (void)handleFeedback;

- (void)showFeedbackDialogue;
- (void)reportFeedback:(NSString*)feedback;

- (void)checkAndCreateAppBladeCacheDirectory;
- (NSString*)captureScreen;
- (UIImage*)getContentBelowView;
- (NSString*)randomString:(int)length;

@end


@implementation AppBlade

@synthesize appBladeProjectID = _appBladeProjectID;
@synthesize appBladeProjectToken = _appBladeProjectToken;
@synthesize appBladeProjectSecret = _appBladeProjectSecret;
@synthesize appBladeProjectIssuedTimestamp = _appBladeProjectIssuedTimestamp;
@synthesize delegate = _delegate;
@synthesize upgradeLink = _upgradeLink;
@synthesize feedbackDictionary = _feedbackDictionary;
@synthesize showingFeedbackDialogue = _showingFeedbackDialogue;
@synthesize tapRecognizer = _tapRecognizer;

static AppBlade *s_sharedManager = nil;

#pragma mark - Lifecycle

+ (NSString*)sdkVersion
{
    return s_sdkVersion;
}

+ (void)logSDKVersion
{
    NSLog(@"AppBlade SDK v %@.", s_sdkVersion);
}

+ (AppBlade *)sharedManager
{
    if (s_sharedManager == nil) {
        s_sharedManager = [[super allocWithZone:NULL] init];
    }
    return s_sharedManager;
}

- (id)init {
    if ((self = [super init])) {
        // Delegate authentication outcomes and other messages are handled by self unless overridden.
        _delegate = self;
    }
    return self;
}

- (void)validateProjectConfiguration
{
    // Validate AppBlade project settings. This should be executed by every public method before proceding.
    if(!self.appBladeProjectID) {
        [self raiseConfigurationExceptionWithFieldName:@"Project ID"];
    } else if (!self.appBladeProjectToken) {
        [self raiseConfigurationExceptionWithFieldName:@"Project Token"];
    } else if (!self.appBladeProjectToken) {
        [self raiseConfigurationExceptionWithFieldName:@"Project Secret"];
    } else if (!self.appBladeProjectIssuedTimestamp) {
        [self raiseConfigurationExceptionWithFieldName:@"Project Issued At Timestamp"];
    }
}

- (void)raiseConfigurationExceptionWithFieldName:(NSString *)name
{
    NSString *exceptionMessageFormat = @"App Blade %@ not set. Configure the shared AppBlade manager from within your "
                                        "application delegate.";
    [NSException raise:@"AppBladeException" format:exceptionMessageFormat, name];
    abort();
}

- (void)dealloc
{   
    [_upgradeLink release];
    [_feedbackDictionary release];
    [super dealloc];
}

#pragma mark

- (void)checkApproval
{
    [self validateProjectConfiguration];

    AppBladeWebClient* client = [[[AppBladeWebClient alloc] initWithDelegate:self] autorelease];
    [client checkPermissions];    
}

- (void)catchAndReportCrashes
{
    [self validateProjectConfiguration];

    PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
    NSError *error;
    
    // Check if we previously crashed
    if ([crashReporter hasPendingCrashReport])
        [self handleCrashReport];
    
    // Enable the Crash Reporter
    if (![crashReporter enableCrashReporterAndReturnError: &error])
        NSLog(@"Warning: Could not enable crash reporter: %@", error);
 
}

- (void)handleCrashReport
{
    PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
    NSData *crashData;
    NSError *error;
    
    // Try loading the crash report
    crashData = [crashReporter loadPendingCrashReportDataAndReturnError: &error];
    if (crashData == nil) {
        [crashReporter purgePendingCrashReport];
        return;
    }
    
    // try to parse the crash data into a PLCrashReport. 
    PLCrashReport *report = [[[PLCrashReport alloc] initWithData: crashData error: &error] autorelease];
    if (report == nil) {
        NSLog(@"Could not parse crash report");
        [crashReporter purgePendingCrashReport];
        return;
    }
    
    NSString* reportString = [PLCrashReportTextFormatter stringValueForCrashReport: report withTextFormat: PLCrashReportTextFormatiOS];
    AppBladeWebClient* client = [[[AppBladeWebClient alloc] initWithDelegate:self] autorelease];
    [client reportCrash:reportString];

}

#pragma mark Feedback


- (void)showFeedbackDialogue{
    
    UIWindow* window = [UIApplication sharedApplication].keyWindow;
    UIInterfaceOrientation interfaceOrientation = [[UIApplication sharedApplication] statusBarOrientation];
    CGRect screenFrame = window.frame;
    
    if (UIInterfaceOrientationIsLandscape(interfaceOrientation)) {
        // We need to react properly to interface orientations
        CGSize size = screenFrame.size;
        screenFrame.size.width = size.height;
        screenFrame.size.height = size.width;
    }
    
    FeedbackDialogue *feedback = [[FeedbackDialogue alloc] initWithFrame:CGRectMake(0, 0, screenFrame.size.width, screenFrame.size.height)];
    feedback.delegate = self;
    
    // get the parent window
    if (!window) 
        window = [[UIApplication sharedApplication].windows objectAtIndex:0];
    [[[window subviews] objectAtIndex:0] addSubview:feedback];   
    self.showingFeedbackDialogue = YES;
    
}

-(void)feedbackDidSubmitText:(NSString*)feedbackText{
    
    NSLog(@"AppBlade received %@", feedbackText);
    [self reportFeedback:feedbackText];
}

- (void)feedbackDidCancel
{
    NSString* screenshotPath = [[AppBlade cachesDirectoryPath] stringByAppendingPathComponent:[self.feedbackDictionary objectForKey:kAppBladeFeedbackKeyScreenshot]];
    [[NSFileManager defaultManager] removeItemAtPath:screenshotPath error:nil];
    self.feedbackDictionary = nil;
}

- (void)allowFeedbackReporting
{
    UIWindow* window = [[UIApplication sharedApplication] keyWindow];
    self.tapRecognizer = [[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleFeedback)] autorelease];
    self.tapRecognizer.numberOfTapsRequired = 2;
    self.tapRecognizer.numberOfTouchesRequired = 3;
    [window addGestureRecognizer:self.tapRecognizer];
}

- (void)handleFeedback
{
    aslmsg q, m;
    int i;
    const char *key, *val;
    
    q = asl_new(ASL_TYPE_QUERY);
    
    aslresponse r = asl_search(NULL, q);
    NSMutableArray* logs = [NSMutableArray arrayWithCapacity:15];
    while (NULL != (m = aslresponse_next(r)))
    {
        NSMutableString* logString = [NSMutableString string];
        [logString appendString:@"{ \t"];
        for (i = 0; (NULL != (key = asl_key(m, i))); i++)
        {
            NSString *keyString = [NSString stringWithUTF8String:(char *)key];
            
            val = asl_get(m, key);
            
            NSString *string = [NSString stringWithUTF8String:val];
            [logString appendString:keyString];
            [logString appendString:@":"];
            [logString appendString:string];
            [logString appendString:@",\n\t"];
        }
        [logString appendString:@"}"];
        [logs addObject:logString];
    }
    aslresponse_free(r);
    
    NSMutableString *consoleString = [NSMutableString stringWithString:@"["];
    [logs enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        NSString* item = (NSString*)obj;
        [consoleString appendString:item];
        if (idx < logs.count - 1) {
            [consoleString appendString:@","];
        }
    }];
    
    [consoleString appendString:@"]"];
    
    self.feedbackDictionary = [NSMutableDictionary dictionaryWithObject:consoleString forKey:kAppBladeFeedbackKeyConsole];
    
    NSString* screenshotPath = [self captureScreen];
    
    [self.feedbackDictionary setObject:[screenshotPath lastPathComponent] forKey:kAppBladeFeedbackKeyScreenshot];
    
    [self showFeedbackDialogue];
}

- (void)reportFeedback:(NSString *)feedback
{
    [self.feedbackDictionary setObject:feedback forKey:kAppBladeFeedbackKeyNotes];
    AppBladeWebClient* client = [[[AppBladeWebClient alloc] initWithDelegate:self] autorelease];
    [client sendFeedbackWithScreenshot:[self.feedbackDictionary objectForKey:kAppBladeFeedbackKeyScreenshot] note:feedback console:[self.feedbackDictionary objectForKey:kAppBladeFeedbackKeyConsole]];
}

- (void)checkAndCreateAppBladeCacheDirectory
{
    NSString* directory = [AppBlade cachesDirectoryPath];
    NSFileManager* manager = [NSFileManager defaultManager];
    BOOL isDirectory = YES;
    if (![manager fileExistsAtPath:directory isDirectory:&isDirectory]) {
        NSError* error = nil;
        BOOL success = [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];
        if (!success) {
            NSLog(@"Error creating directory %@", error);
        }
    }
}

+ (NSString*)cachesDirectoryPath
{
    NSString* cacheDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    return [cacheDirectory stringByAppendingPathComponent:kAppBladeCacheDirectory];
}

-(NSString *)captureScreen
{
    [self checkAndCreateAppBladeCacheDirectory];
    UIImage *currentImage = [self getContentBelowView];
    NSString* fileName = [[self randomString:36] stringByAppendingPathExtension:@"png"];
	NSString *pngFilePath = [[[AppBlade cachesDirectoryPath] stringByAppendingPathComponent:fileName] retain];
	NSData *data1 = [NSData dataWithData:UIImagePNGRepresentation(currentImage)];
	[data1 writeToFile:pngFilePath atomically:YES];
    return [pngFilePath autorelease];
    
}

- (UIImage*)getContentBelowView
{
//    NSArray *windows = [[UIApplication sharedApplication] windows];
//    UIWindow *keyWindow = [windows objectAtIndex:0];
    UIWindow* keyWindow = [[UIApplication sharedApplication] keyWindow];
    UIGraphicsBeginImageContext(keyWindow.bounds.size);
    [keyWindow.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
    
}

-(NSString *) randomString: (int) len {
    
    NSMutableString *randomString = [NSMutableString stringWithCapacity: len];
    
    for (int i=0; i<len; i++) {
        [randomString appendFormat: @"%C", [s_letters characterAtIndex: arc4random()%[s_letters length]]];
    }
    
    return randomString;
}

- (void)closeTTLWindow
{
    [AppBladeSimpleKeychain delete:@"appBlade"];
}

- (void)updateTTL:(NSNumber*)ttl
{
    NSDate* ttlDate = [NSDate date];
    NSDictionary* appBlade = [NSDictionary dictionaryWithObjectsAndKeys:ttlDate, @"ttlDate",ttl, @"ttlInterval", nil];
    [AppBladeSimpleKeychain save:@"appBlade" data:appBlade];
}

// determine if we are within the range of the stored TTL for this application
- (BOOL)withinStoredTTL
{
    NSDictionary* appBlade = [AppBladeSimpleKeychain load:@"appBlade"];
    NSDate* ttlDate = [appBlade objectForKey:@"ttlDate"];
    NSNumber* ttlInterval = [appBlade objectForKey:@"ttlInterval"];
    
    // if we don't have either value, we're definitely not within a stored TTL
    if(nil == ttlInterval || nil == ttlDate)
        return NO;
    
    // if the current date is earlier than our last ttl date, the user has turned their clock back. Invalidate.
    NSDate* currentDate = [NSDate date];
    if ([currentDate compare:ttlDate] == NSOrderedAscending) {
        return NO;
    }
    
    // if the current date is later than the ttl date adjusted with the TTL, the window has expired
    NSDate* adjustedTTLDate = [ttlDate dateByAddingTimeInterval:[ttlInterval integerValue]];
    if ([currentDate compare:adjustedTTLDate] == NSOrderedDescending) {
        return NO;
    }
    
    return YES;
}

#pragma mark - AppBladeWebClient
-(void) appBladeWebClientFailed:(AppBladeWebClient *)client
{
    if (client.api == AppBladeWebClientAPI_Permissions)  {
 
        // check only once if the delegate responds to this selector
        BOOL signalDelegate = [self.delegate respondsToSelector:@selector(appBlade:applicationApproved:error:)];
        
        // if the connection failed, see if the application is still within the previous TTL window. 
        // If it is, then let the application run. Otherwise, ensure that the TTL window is closed and 
        // prevent the app from running until the request completes successfully. This will prevent
        // users from unlocking an app by simply changing their clock.
        if ([self withinStoredTTL]) {
            if(signalDelegate) {
                [self.delegate appBlade:self applicationApproved:YES error:nil];
            }
            
        } 
        else {
            [self closeTTLWindow];
            
            if(signalDelegate) {
                
                NSDictionary* errorDictionary = [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(@"Please check your internet connection to gain access to this application", nil), NSLocalizedDescriptionKey, 
                                                 NSLocalizedString(@"Please check your internet connection to gain access to this application", nil),  NSLocalizedFailureReasonErrorKey, nil];
                
                NSError* error = [NSError errorWithDomain:kAppBladeErrorDomain code:kAppBladeOfflineError userInfo:errorDictionary];
                [self.delegate appBlade:self applicationApproved:NO error:error];                
            }

        }
    }
    
}

- (void)appBladeWebClient:(AppBladeWebClient *)client receivedPermissions:(NSDictionary *)permissions
{
    NSString *errorString = [permissions objectForKey:@"error"];
    
    BOOL signalApproval = [self.delegate respondsToSelector:@selector(appBlade:applicationApproved:error:)];
    
    if (errorString && [self withinStoredTTL]) {
        [self closeTTLWindow];
    
        
        NSDictionary* errorDictionary = [NSDictionary dictionaryWithObjectsAndKeys:NSLocalizedString(errorString, nil), NSLocalizedDescriptionKey, 
                                         NSLocalizedString(errorString, nil),  NSLocalizedFailureReasonErrorKey, nil];
        
        NSError* error = [NSError errorWithDomain:kAppBladeErrorDomain code:kAppBladeOfflineError userInfo:errorDictionary];

        if (signalApproval) 
            [self.delegate appBlade:self applicationApproved:NO error:error];
        
        
    } else {
        
        NSNumber *ttl = [permissions objectForKey:@"ttl"];
        if (ttl) {
            [self updateTTL:ttl];
        }
        
        // tell the client the application was approved. 
        if (signalApproval) {
            [self.delegate appBlade:self applicationApproved:YES error:nil];
        }
        
        
        // determine if there is an update available
        NSDictionary* update = [permissions objectForKey:@"update"];
        if(update) 
        {
            NSString* updateMessage = [update objectForKey:@"message"];
            NSString* updateURL = [update objectForKey:@"url"];
            
            if ([self.delegate respondsToSelector:@selector(appBlade:updateAvailable:updateMessage:updateURL:)]) {
                [self.delegate appBlade:self updateAvailable:YES updateMessage:updateMessage updateURL:updateURL];
            }
        }
    }

    
    
}

- (void)appBladeWebClientCrashReported:(AppBladeWebClient *)client
{
    // purge the crash report that was just reported. 
    PLCrashReporter *crashReporter = [PLCrashReporter sharedReporter];
    [crashReporter purgePendingCrashReport];
}

- (void)appBladeWebClientSentFeedback:(AppBladeWebClient *)client withSuccess:(BOOL)success
{
    if (success) {
        // Clean up
        NSString* screenshotPath = [[AppBlade cachesDirectoryPath] stringByAppendingPathComponent:[self.feedbackDictionary objectForKey:kAppBladeFeedbackKeyScreenshot]];
        [[NSFileManager defaultManager] removeItemAtPath:screenshotPath error:nil];
        self.feedbackDictionary = nil;
    }
    // TODO: Else, save for later

}

#pragma mark - AppBladeDelegate
- (void)appBlade:(AppBlade *)appBlade applicationApproved:(BOOL)approved error:(NSError *)error
{
    if(!approved) {
        
        UIAlertView* alert = [[[UIAlertView alloc] initWithTitle:@"Permission Denied"
                                                         message:[error localizedDescription] 
                                                        delegate:self 
                                               cancelButtonTitle:@"Exit"
                                               otherButtonTitles: nil] autorelease];
        [alert show];
    }
    
}


-(void) appBlade:(AppBlade *)appBlade updateAvailable:(BOOL)update updateMessage:(NSString*)message updateURL:(NSString*)url
{
    if (update) {
        
        UIAlertView* alert = [[[UIAlertView alloc] initWithTitle:@"Update Available"
                                                         message:message
                                                        delegate:self 
                                               cancelButtonTitle:@"Cancel"
                                               otherButtonTitles: @"Upgrade", nil] autorelease];
        alert.tag = kUpdateAlertTag;
        self.upgradeLink = [NSURL URLWithString:url];
        
        [alert show];
      
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (alertView.tag == kUpdateAlertTag) {
        if (buttonIndex == 1) {
            [[UIApplication sharedApplication] openURL:self.upgradeLink];
            self.upgradeLink = nil;   
            exit(0);
        }
    } else {
        exit(0);
    }
}

@end
