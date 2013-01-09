#import "DocumentController.h"
#import "ProjectLayoutView.h"
#import "DocumentOpenHelper.h"
#import "DocumentSaveHelper.h"
#import "DocumentCommand.h" // show_command_error
#import <OakAppKit/NSAlert Additions.h>
#import <OakAppKit/NSMenuItem Additions.h>
#import <OakAppKit/OakAppKit.h>
#import <OakAppKit/OakFileIconImage.h>
#import <OakAppKit/OakPasteboard.h>
#import <OakAppKit/OakSavePanel.h>
#import <OakAppKit/OakSubmenuController.h>
#import <OakAppKit/OakTabBarView.h>
#import <OakAppKit/OakWindowFrameHelper.h>
#import <OakFoundation/NSArray Additions.h>
#import <OakFoundation/NSString Additions.h>
#import <Preferences/Keys.h>
#import <OakTextView/OakDocumentView.h>
#import <OakFileBrowser/OakFileBrowser.h>
#import <HTMLOutputWindow/HTMLOutputWindow.h>
#import <OakFilterList/OakFileChooser.h>
#import <OakFilterList/SymbolChooser.h>
#import <Find/Find.h>
#import <document/session.h>
#import <file/path_info.h>
#import <io/entries.h>
#import <scm/scm.h>
#import <text/utf8.h>
#import <ns/ns.h>

namespace find_tags { enum { in_document = 1, in_selection, in_project, in_folder }; } // From AppController.h

NSString* const OakDocumentWindowWillCloseNotification = @"OakDocumentWindowWillCloseNotification";
static NSString* const OakDocumentPboardType = @"OakDocumentPboardType"; // drag’n’drop of tabs

@interface DocumentController () <NSWindowDelegate, OakTabBarViewDelegate, OakTabBarViewDataSource, OakTextViewDelegate, OakFileBrowserDelegate>
@property (nonatomic) ProjectLayoutView*          layoutView;
@property (nonatomic) OakTabBarView*              tabBarView;
@property (nonatomic) OakDocumentView*            documentView;
@property (nonatomic) OakTextView*                textView;
@property (nonatomic) OakFileBrowser*             fileBrowser;

@property (nonatomic) HTMLOutputWindowController* htmlOutputWindowController;
@property (nonatomic) OakHTMLOutputView*          htmlOutputView;
@property (nonatomic) BOOL                        htmlOutputInWindow;

@property (nonatomic) NSString*                   windowTitle;
@property (nonatomic) NSString*                   representedFile;
@property (nonatomic) BOOL                        isDocumentEdited;

@property (nonatomic) NSString*                   pathAttributes;
@property (nonatomic) NSString*                   projectPath;

@property (nonatomic) OakFilterWindowController*  filterWindowController;
@property (nonatomic) NSUInteger                  fileChooserSourceIndex;

@property (nonatomic) BOOL                        applicationTerminationEventLoopRunning;

- (void)makeTextViewFirstResponder:(id)sender;
- (void)updatePathDependentProperties;
- (void)updateFileBrowserStatus:(id)sender;
- (void)documentDidChange:(document::document_ptr const&)aDocument;

- (void)fileBrowser:(OakFileBrowser*)aFileBrowser openURLs:(NSArray*)someURLs;
- (void)fileBrowser:(OakFileBrowser*)aFileBrowser closeURL:(NSURL*)anURL;

- (void)takeNewTabIndexFrom:(id)sender;   // used by newDocumentInTab:
- (void)takeTabsToTearOffFrom:(id)sender; // used by moveDocumentToNewWindow:
@end

namespace
{
	struct tracking_info_t : document::document_t::callback_t
	{
		tracking_info_t (DocumentController* self, document::document_ptr const& document) : _self(self), _document(document) { }
		~tracking_info_t () { ASSERT_EQ(_open_count, 0); }

		void track ()
		{
			if(++_open_count == 1)
			{
				_document->add_callback(this);
				// TODO Add kqueue watching of documents
			}

			if(!_did_open && _document->is_open())
			{
				_document->open();
				_did_open = true;
			}
		}

		bool untrack ()
		{
			if(_open_count == 1)
				_document->remove_callback(this);

			if(--_open_count == 0 && _did_open)
			{
				_document->close();
				_did_open = false;
			}
			return _open_count == 0;
		}

		void handle_document_event (document::document_ptr document, event_t event)
		{
			switch(event)
			{
				case did_change_path:
				case did_change_on_disk_status:
				case did_change_modified_status:
					[_self documentDidChange:document];
				break;
			}
		}

	private:
		__weak DocumentController* _self;
		document::document_ptr _document;
		size_t _open_count = 0;
		bool _did_open = false;
	};

	static bool is_disposable (document::document_ptr const& doc)
	{
		return doc && !doc->is_modified() && !doc->is_on_disk() && doc->path() == NULL_STR && doc->buffer().empty();
	}

	static size_t merge_documents_splitting_at (std::vector<document::document_ptr> const& oldDocuments, std::vector<document::document_ptr> const& newDocuments, size_t splitAt, std::vector<document::document_ptr>& out)
	{
		std::set<oak::uuid_t> uuids;
		std::transform(newDocuments.begin(), newDocuments.end(), std::insert_iterator<decltype(uuids)>(uuids, uuids.begin()), [](document::document_ptr const& doc){ return doc->identifier(); });

		splitAt = std::min(splitAt, oldDocuments.size());
		std::copy_if(oldDocuments.begin(), oldDocuments.begin() + splitAt, back_inserter(out), [&uuids](document::document_ptr const& doc){ return uuids.find(doc->identifier()) == uuids.end(); });
		size_t res = out.size();
		std::copy(newDocuments.begin(), newDocuments.end(), back_inserter(out));	
		std::copy_if(oldDocuments.begin() + splitAt, oldDocuments.end(), back_inserter(out), [&uuids](document::document_ptr const& doc){ return uuids.find(doc->identifier()) == uuids.end(); });
		return res;
	}

	static std::vector<document::document_ptr> make_vector (document::document_ptr const& document)
	{
		return std::vector<document::document_ptr>(1, document);
	}

	static document::document_ptr create_untitled_document_in_folder (std::string const& suggestedFolder)
	{
		return document::from_content("", settings_for_path(NULL_STR, file::path_attributes(NULL_STR), suggestedFolder).get(kSettingsFileTypeKey, "text.plain"));
	}
}

@implementation DocumentController
{
	OBJC_WATCH_LEAKS(DocumentController);

	std::vector<document::document_ptr>    _documents;
	std::map<oak::uuid_t, tracking_info_t> _trackedDocuments;
	document::document_ptr                 _selectedDocument;
	command::runner_ptr                    _runner;

	scm::info_ptr                          _scmInfo;
	scm::callback_t*                       _scmCallback;
}

- (id)init
{
	if((self = [super init]))
	{
		self.identifier  = [NSString stringWithCxxString:oak::uuid_t().generate()];
		self.windowTitle = @"untitled";
		self.htmlOutputInWindow = [[[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsHTMLOutputPlacementKey] isEqualToString:@"window"];

		self.tabBarView = [[OakTabBarView alloc] initWithFrame:NSZeroRect];
		self.tabBarView.dataSource = self;
		self.tabBarView.delegate   = self;

		self.documentView = [[OakDocumentView alloc] init];
		self.textView = self.documentView.textView;
		self.textView.delegate = self;

		self.layoutView = [[ProjectLayoutView alloc] initWithFrame:NSZeroRect];
		self.layoutView.tabBarView   = self.tabBarView;
		self.layoutView.documentView = self.documentView;

		self.window = [[NSWindow alloc] initWithContentRect:NSZeroRect styleMask:(NSTitledWindowMask|NSClosableWindowMask|NSResizableWindowMask|NSMiniaturizableWindowMask|NSTexturedBackgroundWindowMask) backing:NSBackingStoreBuffered defer:NO];
		self.window.autorecalculatesKeyViewLoop = YES;
		self.window.collectionBehavior          = NSWindowCollectionBehaviorFullScreenPrimary;
		self.window.contentView                 = self.layoutView;
		self.window.delegate                    = self;
		self.window.releasedWhenClosed          = NO;
		[self.window bind:@"title" toObject:self withKeyPath:@"windowTitle" options:nil];
		[self.window bind:@"documentEdited" toObject:self withKeyPath:@"isDocumentEdited" options:nil];

		[OakWindowFrameHelper windowFrameHelperWithWindow:self.window];

		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:[NSUserDefaults standardUserDefaults]];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActiveNotification:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidResignActiveNotification:) name:NSApplicationDidResignActiveNotification object:NSApp];
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];

	if(_scmInfo)
		_scmInfo->remove_callback(_scmCallback);
	delete _scmCallback;

	self.tabBarView.dataSource  = nil;
	self.tabBarView.delegate    = nil;
	self.textView.delegate      = nil;
	self.filterWindowController = nil; // ensures we removeObserver: and set target to nil
}

- (void)windowWillClose:(NSNotification*)aNotification
{
	self.documents        = std::vector<document::document_ptr>();
	self.selectedDocument = document::document_ptr();

	[self.window unbind:@"title"];
	[self.window unbind:@"documentEdited"];
	self.window.delegate = nil;

	[[NSNotificationCenter defaultCenter] postNotificationName:OakDocumentWindowWillCloseNotification object:self];
}

- (void)showWindow:(id)sender                 { [self.window makeKeyAndOrderFront:sender]; }
- (void)makeTextViewFirstResponder:(id)sender { [self.window makeFirstResponder:self.textView]; }
- (void)close                                 { [self.window close]; }

// ==========================
// = Notification Callbacks =
// ==========================

- (void)userDefaultsDidChange:(NSNotification*)aNotification
{
	self.htmlOutputInWindow = [[[NSUserDefaults standardUserDefaults] objectForKey:kUserDefaultsHTMLOutputPlacementKey] isEqualToString:@"window"];
}

- (void)applicationDidBecomeActiveNotification:(NSNotification*)aNotification
{
	if(!self.documents.empty())
		[self.textView performSelector:@selector(applicationDidBecomeActiveNotification:) withObject:aNotification];
	[self updatePathDependentProperties];
}

- (void)applicationDidResignActiveNotification:(NSNotification*)aNotification
{
	if(!self.documents.empty())
		[self.textView performSelector:@selector(applicationDidResignActiveNotification:) withObject:aNotification];
}

// =================
// = Close Methods =
// =================

- (void)showCloseWarningUIForDocuments:(std::vector<document::document_ptr> const&)someDocuments completionHandler:(void(^)(BOOL canClose))callback
{
	if(someDocuments.empty())
		return callback(YES);

	[[self.window attachedSheet] orderOut:self];
	NSAlert* alert = [[NSAlert alloc] init];
	[alert setAlertStyle:NSWarningAlertStyle];
	[alert addButtons:@"Save", @"Cancel", @"Don’t Save", nil];
	if(someDocuments.size() == 1)
	{
		document::document_ptr document = someDocuments.front();
		[alert setMessageText:[NSString stringWithCxxString:text::format("Do you want to save the changes you made in the document “%s”?", document->display_name().c_str())]];
		[alert setInformativeText:@"Your changes will be lost if you don’t save them."];
	}
	else
	{
		std::string body = "";
		iterate(document, someDocuments)
			body += text::format("• “%s”\n", (*document)->display_name().c_str());
		[alert setMessageText:@"Do you want to save documents with changes?"];
		[alert setInformativeText:[NSString stringWithCxxString:body]];
	}

	bool windowModal = true;
	if(someDocuments.size() == 1)
	{
		citerate(document, self.documents)
		{
			if((*document)->identifier() == someDocuments.front()->identifier())
			{
				self.selectedTabIndex = document - self.documents.begin();
				[self openAndSelectDocument:*document];
				break;
			}
		}
	}
	else
	{
		std::set<oak::uuid_t> uuids;
		std::transform(self.documents.begin(), self.documents.end(), std::insert_iterator<decltype(uuids)>(uuids, uuids.begin()), [](document::document_ptr const& doc){ return doc->identifier(); });

		iterate(document, someDocuments)
		{
			if(uuids.find((*document)->identifier()) == uuids.end())
				windowModal = false;
		}
	}

	std::vector<document::document_ptr> documentsToSave(someDocuments);
	auto block = ^(NSInteger returnCode)
	{
		switch(returnCode)
		{
			case NSAlertFirstButtonReturn: /* "Save" */
			{
				struct callback_t : document_save_callback_t
				{
					callback_t (void(^callback)(BOOL), size_t count) : _callback([callback copy]), _count(count) { }

					void did_save_document (document::document_ptr document, bool flag, std::string const& message, oak::uuid_t const& filter)
					{
						if(_callback && (_count == 1 || !flag))
							_callback(flag);

						if(--_count == 0 || !flag)
							delete this;
					}

				private:
					void(^_callback)(BOOL);
					size_t _count;
				};

				if(self.applicationTerminationEventLoopRunning)
				{
					self.applicationTerminationEventLoopRunning = NO;
					[NSApp replyToApplicationShouldTerminate:NO];
				}

				[DocumentSaveHelper trySaveDocuments:documentsToSave forWindow:self.window defaultDirectory:self.untitledSavePath andCallback:new callback_t(callback, documentsToSave.size())];
			}
			break;

			case NSAlertSecondButtonReturn: /* "Cancel" */
			{
				callback(NO);
			}
			break;

			case NSAlertThirdButtonReturn: /* "Don't Save" */
			{
				callback(YES);
			}
			break;
		}
	};

	if(windowModal)
			OakShowAlertForWindow(alert, self.window, block);
	else	block([alert runModal]);
}

- (void)closeTabsAtIndexes:(NSIndexSet*)anIndexSet askToSaveChanges:(BOOL)askToSaveFlag createDocumentIfEmpty:(BOOL)createIfEmptyFlag
{
	std::vector<document::document_ptr> documentsToClose;
	for(NSUInteger index = [anIndexSet firstIndex]; index != NSNotFound; index = [anIndexSet indexGreaterThanIndex:index])
		documentsToClose.push_back([self documents][index]);

	if(askToSaveFlag)
	{
		std::vector<document::document_ptr> documents;
		std::copy_if(documentsToClose.begin(), documentsToClose.end(), back_inserter(documents), [](document::document_ptr const& doc){ return doc->is_modified(); });

		if(!documents.empty())
		{
			[self showCloseWarningUIForDocuments:documents completionHandler:^(BOOL canClose){
				if(canClose)
				{
					[self closeTabsAtIndexes:anIndexSet askToSaveChanges:NO createDocumentIfEmpty:createIfEmptyFlag];
				}
				else
				{
					NSMutableIndexSet* newIndexes = [anIndexSet mutableCopy];
					for(NSUInteger index = [anIndexSet firstIndex]; index != NSNotFound; index = [anIndexSet indexGreaterThanIndex:index])
					{
						if([self documents][index]->is_modified())
							[newIndexes removeIndex:index];
					}
					[self closeTabsAtIndexes:newIndexes askToSaveChanges:YES createDocumentIfEmpty:createIfEmptyFlag];
				}
			}];
			return;
		}
	}

	std::set<oak::uuid_t> uuids;
	std::transform(documentsToClose.begin(), documentsToClose.end(), std::insert_iterator<decltype(uuids)>(uuids, uuids.begin()), [](document::document_ptr const& doc){ return doc->identifier(); });

	std::vector<document::document_ptr> newDocuments;
	NSUInteger newSelectedTabIndex = self.selectedTabIndex;
	oak::uuid_t const selectedUUID = [self documents][self.selectedTabIndex]->identifier();
	citerate(document, self.documents)
	{
		oak::uuid_t const& uuid = (*document)->identifier();
		if(uuids.find(uuid) == uuids.end())
			newDocuments.push_back((*document));
		if(selectedUUID == uuid)
			newSelectedTabIndex = newDocuments.empty() ? 0 : newDocuments.size() - 1;
	}

	if(createIfEmptyFlag && newDocuments.empty())
		newDocuments.push_back(create_untitled_document_in_folder(to_s(self.untitledSavePath)));

	self.selectedTabIndex = newSelectedTabIndex;
	self.documents        = newDocuments;

	if(!newDocuments.empty() && newDocuments[newSelectedTabIndex]->identifier() != selectedUUID)
		[self openAndSelectDocument:newDocuments[newSelectedTabIndex]];
}

- (IBAction)performCloseTab:(id)sender
{
	if(self.documents.empty() || self.documents.size() == 1 && (is_disposable(self.selectedDocument) || !self.fileBrowserVisible))
		return [self performCloseWindow:sender];
	NSUInteger index = [sender isKindOfClass:[OakTabBarView class]] ? [sender tag] : self.selectedTabIndex;
	[self closeTabsAtIndexes:[NSIndexSet indexSetWithIndex:index] askToSaveChanges:YES createDocumentIfEmpty:YES];
}

- (IBAction)performCloseSplit:(id)sender
{
	ASSERT(sender == self.layoutView.htmlOutputView);
	self.htmlOutputVisible = NO;
}

- (IBAction)performCloseWindow:(id)sender
{
	[self.window performClose:self];
}

- (IBAction)performCloseOtherTabs:(id)sender
{
	NSUInteger tabIndex = [sender isKindOfClass:[OakTabBarView class]] ? [sender tag] : self.selectedTabIndex;

	NSMutableIndexSet* otherTabs = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.documents.size())];
	[otherTabs removeIndex:tabIndex];
	[self closeTabsAtIndexes:otherTabs askToSaveChanges:YES createDocumentIfEmpty:YES];
}

- (void)pruneExcessTabs:(id)sender // TODO Enable tab pruning
{
	std::set<oak::uuid_t> newDocs;

	NSInteger excessTabs = self.documents.size() - self.tabBarView.countOfVisibleTabs;
	if(self.tabBarView && excessTabs > 0)
	{
		std::multimap<oak::date_t, size_t> ranked;
		for(size_t i = 0; i < self.documents.size(); ++i)
		{
			document::document_ptr doc = [self documents][i];
			if(!doc->is_modified() && doc->is_on_disk() && newDocs.find(doc->identifier()) == newDocs.end())
				ranked.insert(std::make_pair(doc->lru(), i));
		}

		NSMutableIndexSet* indexSet = [NSMutableIndexSet indexSet];
		iterate(pair, ranked)
		{
			[indexSet addIndex:pair->second];
			if([indexSet count] == excessTabs)
				break;
		}

		[self closeTabsAtIndexes:indexSet askToSaveChanges:NO createDocumentIfEmpty:NO];
	}
}

- (BOOL)windowShouldClose:(id)sender
{
	[self.htmlOutputView stopLoading];

	std::vector<document::document_ptr> documents;
	std::copy_if(self.documents.begin(), self.documents.end(), back_inserter(documents), [](document::document_ptr const& doc){ return doc->is_modified(); });

	if(documents.empty())
		return YES;

	[self showCloseWarningUIForDocuments:documents completionHandler:^(BOOL canClose){
		if(canClose)
			[self.window close];
	}];

	return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication*)sender
{
	std::vector<document::document_ptr> documents;
	for(NSWindow* window in [NSApp orderedWindows])
	{
		DocumentController* delegate = (DocumentController*)[window delegate];
		if([delegate isKindOfClass:[DocumentController class]])
			std::copy_if(delegate.documents.begin(), delegate.documents.end(), back_inserter(documents), [](document::document_ptr const& doc){ return doc->is_modified(); });
	}

	if(documents.empty())
		return NSTerminateNow;

	self.applicationTerminationEventLoopRunning = YES;
	[self showCloseWarningUIForDocuments:documents completionHandler:^(BOOL canClose){
		if(canClose)
			document::save_session(false);

		if(self.applicationTerminationEventLoopRunning)
			[NSApp replyToApplicationShouldTerminate:canClose];
		else if(canClose)
			[NSApp terminate:self];

		self.applicationTerminationEventLoopRunning = NO;
	}];

	return NSTerminateLater;
}

// =====================
// = Document Tracking =
// =====================

- (void)trackDocument:(document::document_ptr)aDocument
{
	if(aDocument)
	{
		auto iter = _trackedDocuments.find(aDocument->identifier());
		if(iter == _trackedDocuments.end())
			iter = _trackedDocuments.insert(std::make_pair(aDocument->identifier(), tracking_info_t(self, aDocument))).first;
		iter->second.track();
	}
}

- (void)untrackDocument:(document::document_ptr)aDocument
{
	if(aDocument)
	{
		auto iter = _trackedDocuments.find(aDocument->identifier());
		ASSERT(iter != _trackedDocuments.end());
		if(iter->second.untrack())
			_trackedDocuments.erase(iter);
	}
}

- (void)documentDidChange:(document::document_ptr const&)aDocument
{
	[self updatePathDependentProperties];
	[self updateFileBrowserStatus:self];
	[self.tabBarView reloadData];
	document::schedule_session_backup();
}

// ====================
// = Create Documents =
// ====================

- (IBAction)newDocumentInTab:(id)sender
{
	[self takeNewTabIndexFrom:[NSIndexSet indexSetWithIndex:self.selectedTabIndex + 1]];
}

- (IBAction)moveDocumentToNewWindow:(id)sender
{
	if(self.documents.size() > 1)
		[self takeTabsToTearOffFrom:[NSIndexSet indexSetWithIndex:self.selectedTabIndex]];
}

- (IBAction)mergeAllWindows:(id)sender
{
	std::vector<document::document_ptr> documents = self.documents;
	for(NSWindow* window in [NSApp orderedWindows])
	{
		if([window isMiniaturized])
			continue;

		DocumentController* delegate = (DocumentController*)[window delegate];
		if(delegate != self && [delegate isKindOfClass:[DocumentController class]])
			documents.insert(documents.end(), delegate.documents.begin(), delegate.documents.end());
	}

	self.documents = documents;

	for(NSWindow* window in [NSApp orderedWindows])
	{
		if(![window isMiniaturized] && window != self.window && [window.delegate isKindOfClass:[DocumentController class]])
			[window close];
	}
}

- (void)openItems:(NSArray*)items closingOtherTabs:(BOOL)closeOtherTabsFlag
{
	std::vector<document::document_ptr> documents;
	for(id item in items)
	{
		std::string const path  = to_s((NSString*)[item objectForKey:@"path"]);
		std::string const uuid  = to_s((NSString*)[item objectForKey:@"identifier"]);
		std::string const range = to_s((NSString*)[item objectForKey:@"selectionString"]);

		document::document_ptr doc = path == NULL_STR && oak::uuid_t::is_valid(uuid) ? document::find(uuid) : document::create(path);
		doc->set_recent_tracking(false);
		if(range != NULL_STR)
			doc->set_selection(range);
		documents.push_back(doc);
	}

	std::vector<document::document_ptr> oldDocuments = self.documents;
	NSUInteger split = self.selectedTabIndex;

	if(!oldDocuments.empty() && is_disposable(oldDocuments[split]))
			oldDocuments.erase(oldDocuments.begin() + split);
	else	++split;

	std::vector<document::document_ptr> newDocuments;
	split = merge_documents_splitting_at(oldDocuments, documents, split, newDocuments);

	self.documents        = newDocuments;
	self.selectedTabIndex = split;

	if(!newDocuments.empty())
		[self openAndSelectDocument:newDocuments[split]];

	if(closeOtherTabsFlag)
	{
		std::set<oak::uuid_t> uuids;
		std::transform(documents.begin(), documents.end(), std::insert_iterator<decltype(uuids)>(uuids, uuids.begin()), [](document::document_ptr const& doc){ return doc->identifier(); });

		NSMutableIndexSet* indexSet = [NSMutableIndexSet indexSet];
		for(size_t i = 0; i < newDocuments.size(); ++i)
		{
			if(uuids.find(newDocuments[i]->identifier()) == uuids.end())
				[indexSet addIndex:i];
		}
		[self closeTabsAtIndexes:indexSet askToSaveChanges:YES createDocumentIfEmpty:NO];
	}
}

// ================
// = Document I/O =
// ================

- (void)openAndSelectDocument:(document::document_ptr const&)aDocument
{
	document::document_ptr doc = aDocument;
	[[DocumentOpenHelper new] tryOpenDocument:doc forWindow:self.window completionHandler:^(std::string const& error, oak::uuid_t const& filterUUID){
		if(error == NULL_STR)
		{
			[self makeTextViewFirstResponder:self];
			[self setSelectedDocument:doc];
		}
		else
		{
			if(filterUUID)
				show_command_error(error, filterUUID);

			[self openAndSelectDocument:document::from_content("TODO Reselect previously open document")];
		}
	}];
}

namespace
{
	struct save_callback_t : document_save_callback_t
	{
		save_callback_t (DocumentController* self) : _self(self) { }

		void did_save_document (document::document_ptr document, bool flag, std::string const& message, oak::uuid_t const& filter)
		{
			if(flag)
				[_self documentDidChange:document];
			delete this;
		}

	private:
		__weak DocumentController* _self;
	};
}

- (IBAction)saveDocument:(id)sender
{
	if([self selectedDocument]->path() != NULL_STR)
	{
		[DocumentSaveHelper trySaveDocument:[self selectedDocument] forWindow:self.window defaultDirectory:nil andCallback:new save_callback_t(self)];
	}
	else
	{
		NSString* const suggestedFolder  = self.untitledSavePath;
		NSString* const suggestedName    = DefaultSaveNameForDocument([self selectedDocument]);
		encoding::type suggestedEncoding = [self selectedDocument]->encoding_for_save_as_path(to_s([suggestedFolder stringByAppendingPathComponent:suggestedName]));
		[OakSavePanel showWithPath:suggestedName directory:suggestedFolder fowWindow:self.window encoding:suggestedEncoding completionHandler:^(NSString* path, encoding::type const& encoding){
			if(!path)
				return;

			std::vector<std::string> const& paths = path::expand_braces(to_s(path));
			ASSERT_LT(0, paths.size());

			[self selectedDocument]->set_path(paths[0]);
			[self selectedDocument]->set_disk_encoding(encoding);

			// if([self selectedDocument]->identifier() == scratchDocument)
			// 	scratchDocument = oak::uuid_t();

			if(paths.size() > 1)
			{
				 // FIXME check if paths[0] already exists (overwrite)

				std::vector<document::document_ptr> documents, newDocuments;
				std::transform(paths.begin() + 1, paths.end(), back_inserter(documents), [&encoding](std::string const& path) -> document::document_ptr {
					document::document_ptr doc = document::create(path);
					doc->set_disk_encoding(encoding);
					return doc;
				});

				merge_documents_splitting_at(self.documents, documents, self.selectedTabIndex + 1, newDocuments);
				self.documents = newDocuments;
			}

			[DocumentSaveHelper trySaveDocument:self.selectedDocument forWindow:self.window defaultDirectory:nil andCallback:new save_callback_t(self)];
			[self updatePathDependentProperties];
		}];
	}
}

- (IBAction)saveDocumentAs:(id)sender
{
	std::string const documentPath   = [self selectedDocument]->path();
	NSString* const suggestedFolder  = [NSString stringWithCxxString:path::parent(documentPath)] ?: self.untitledSavePath;
	NSString* const suggestedName    = [NSString stringWithCxxString:path::name(documentPath)]   ?: DefaultSaveNameForDocument([self selectedDocument]);
	encoding::type suggestedEncoding = [self selectedDocument]->encoding_for_save_as_path(to_s([suggestedFolder stringByAppendingPathComponent:suggestedName]));
	[OakSavePanel showWithPath:suggestedName directory:suggestedFolder fowWindow:self.window encoding:suggestedEncoding completionHandler:^(NSString* path, encoding::type const& encoding){
		if(!path)
			return;
		[self selectedDocument]->set_path(to_s(path));
		[self selectedDocument]->set_disk_encoding(encoding);
		[DocumentSaveHelper trySaveDocument:self.selectedDocument forWindow:self.window defaultDirectory:nil andCallback:new save_callback_t(self)];
		[self updatePathDependentProperties];
	}];
}

- (IBAction)saveAllDocuments:(id)sender
{
	std::vector<document::document_ptr> documentsToSave;
	citerate(document, self.documents)
	{
		if((*document)->is_modified())
			documentsToSave.push_back(*document);
	}
	[DocumentSaveHelper trySaveDocuments:documentsToSave forWindow:self.window defaultDirectory:self.untitledSavePath andCallback:new save_callback_t(self)];
}

// ================
// = Window Title =
// ================

- (void)updateProxyIcon
{
	self.window.representedFilename = self.representedFile ?: @"";
	[self.window standardWindowButton:NSWindowDocumentIconButton].image = self.representedFile ? [OakFileIconImage fileIconImageWithPath:self.representedFile isModified:NO] : nil;
}

- (void)setRepresentedFile:(NSString*)aPath
{
	if(![_representedFile isEqualToString:aPath])
	{
		struct scm_callback_t : scm::callback_t
		{
			scm_callback_t (DocumentController* self) : _self(self) { }
	
			void status_changed (scm::info_t const& info, std::set<std::string> const& changedPaths)
			{
				if(changedPaths.find(to_s(_self.representedFile)) != changedPaths.end())
					[_self updateProxyIcon];
			}
	
		private:
			__weak DocumentController* _self;
		};

		if(_scmInfo)
		{
			_scmInfo->remove_callback(_scmCallback);
			_scmInfo.reset();
		}

		if(aPath && ![aPath isEqualToString:@""])
		{
			if(!_scmCallback)
				_scmCallback = new scm_callback_t(self);

			if(_scmInfo = scm::info(path::parent(to_s(aPath))))
				_scmInfo->add_callback(_scmCallback);
		}

		_representedFile = aPath;
		[self updateProxyIcon];
	}
}

- (void)updatePathDependentProperties
{
	document::document_ptr doc = self.selectedDocument;
	if(!doc)
	{
		self.windowTitle      = @"«no documents»";
		self.representedFile  = @"";
		self.isDocumentEdited = NO;
		return;
	}

	std::string docDirectory = doc->path() != NULL_STR ? path::parent(doc->path()) : to_s(self.untitledSavePath);
	self.pathAttributes = [NSString stringWithCxxString:file::path_attributes(doc->path(), docDirectory)];

	std::map<std::string, std::string> map;
	if(doc->path() == NULL_STR)
	{
		if(scm::info_ptr info = scm::info(docDirectory))
		{
			std::string const& branch = info->branch();
			if(branch != NULL_STR)
				map["TM_SCM_BRANCH"] = branch;

			std::string const& name = info->scm_name();
			if(name != NULL_STR)
				map["TM_SCM_NAME"] = name;
		}
	}

	if(NSString* projectPath = self.defaultProjectPath ?: self.fileBrowser.location ?: [NSString stringWithCxxString:path::parent(doc->path())])
		map["projectDirectory"] = to_s(projectPath);

	settings_t const settings = settings_for_path(doc->virtual_path(), doc->file_type() + " " + to_s(self.scopeAttributes), docDirectory, doc->variables(map, false));

	self.projectPath      = [NSString stringWithCxxString:settings.get(kSettingsProjectDirectoryKey, NULL_STR)];
	self.windowTitle      = [NSString stringWithCxxString:settings.get(kSettingsWindowTitleKey, doc->display_name())];
	self.representedFile  = doc->is_on_disk() ? [NSString stringWithCxxString:doc->path()] : nil;
	self.isDocumentEdited = doc->is_modified();
}

// ========================
// = OakTextView Delegate =
// ========================

- (NSString*)scopeAttributes
{
	return self.pathAttributes;
}

// ==============
// = Properties =
// ==============

- (void)setDocuments:(std::vector<document::document_ptr> const&)newDocuments
{
	iterate(doc, newDocuments)
		[self trackDocument:*doc];
	iterate(doc, _documents)
		[self untrackDocument:*doc];

	_documents = newDocuments;

	if(_documents.size())
		[self.tabBarView reloadData];

	[self updateFileBrowserStatus:self];
	document::schedule_session_backup();
}

- (void)setSelectedDocument:(document::document_ptr const&)newSelectedDocument
{
	ASSERT(!newSelectedDocument || newSelectedDocument->is_open());
	if(_selectedDocument == newSelectedDocument)
	{
		[self.documentView setDocument:_selectedDocument];
		return;
	}

	[self trackDocument:newSelectedDocument];
	[self untrackDocument:_selectedDocument];

	if(_selectedDocument = newSelectedDocument)
		[self.documentView setDocument:_selectedDocument];

	[self updatePathDependentProperties];
	document::schedule_session_backup();
}

- (void)setSelectedTabIndex:(NSUInteger)newSelectedTabIndex
{
	_selectedTabIndex = newSelectedTabIndex;
	[self.tabBarView setSelectedTab:newSelectedTabIndex];
}

// ===========================
// = OakTabBarViewDataSource =
// ===========================

- (NSUInteger)numberOfRowsInTabBarView:(OakTabBarView*)aTabBarView                      { return _documents.size(); }
- (NSString*)tabBarView:(OakTabBarView*)aTabBarView titleForIndex:(NSUInteger)anIndex   { return [NSString stringWithCxxString:_documents[anIndex]->display_name()]; }
- (NSString*)tabBarView:(OakTabBarView*)aTabBarView toolTipForIndex:(NSUInteger)anIndex { return [NSString stringWithCxxString:path::with_tilde(_documents[anIndex]->path())] ?: @""; }
- (BOOL)tabBarView:(OakTabBarView*)aTabBarView isEditedAtIndex:(NSUInteger)anIndex      { return _documents[anIndex]->is_modified(); }

// ==============================
// = OakTabBarView Context Menu =
// ==============================

- (NSIndexSet*)tryObtainIndexSetFrom:(id)sender
{
	id res = sender;
	if([sender respondsToSelector:@selector(representedObject)])
		res = [sender representedObject];
	return [res isKindOfClass:[NSIndexSet class]] ? res : nil;
}

- (void)takeNewTabIndexFrom:(id)sender
{
	if(NSIndexSet* indexSet = [self tryObtainIndexSetFrom:sender])
	{
		document::document_ptr doc = create_untitled_document_in_folder(to_s(self.untitledSavePath));
		doc->open();
		[self setSelectedDocument:doc];
		doc->close();

		std::vector<document::document_ptr> newDocuments;
		size_t pos = merge_documents_splitting_at(self.documents, make_vector(doc), [indexSet firstIndex], newDocuments);
		self.documents        = newDocuments;
		self.selectedTabIndex = pos;
	}
}

- (void)takeTabsToCloseFrom:(id)sender
{
	if(NSIndexSet* indexSet = [self tryObtainIndexSetFrom:sender])
		[self closeTabsAtIndexes:indexSet askToSaveChanges:YES createDocumentIfEmpty:YES];
}

- (void)takeTabsToTearOffFrom:(id)sender
{
	if(NSIndexSet* indexSet = [self tryObtainIndexSetFrom:sender])
	{
		std::vector<document::document_ptr> documents;
		for(NSUInteger index = [indexSet firstIndex]; index != NSNotFound; index = [indexSet indexGreaterThanIndex:index])
			documents.push_back([self documents][index]);

		if(documents.size() == 1)
		{
			document::show(documents[0], document::kCollectionNew);
			[self closeTabsAtIndexes:indexSet askToSaveChanges:NO createDocumentIfEmpty:YES];
		}
	}
}

- (NSMenu*)menuForTabBarView:(OakTabBarView*)aTabBarView
{
	NSInteger tabIndex = aTabBarView.tag;
	NSInteger total    = self.documents.size();

	NSMutableIndexSet* newTabAtTab   = tabIndex == -1 ? [NSMutableIndexSet indexSetWithIndex:total] : [NSMutableIndexSet indexSetWithIndex:tabIndex + 1];
	NSMutableIndexSet* clickedTab    = tabIndex == -1 ? [NSMutableIndexSet indexSet] : [NSMutableIndexSet indexSetWithIndex:tabIndex];
	NSMutableIndexSet* otherTabs     = tabIndex == -1 ? [NSMutableIndexSet indexSet] : [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, total)];
	NSMutableIndexSet* rightSideTabs = tabIndex == -1 ? [NSMutableIndexSet indexSet] : [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, total)];

	if(tabIndex != -1)
	{
		[otherTabs removeIndex:tabIndex];
		[rightSideTabs removeIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, tabIndex + 1)]];
	}

	SEL closeSingleTabSelector = tabIndex == self.selectedTabIndex ? @selector(performCloseTab:) : @selector(takeTabsToCloseFrom:);

	NSMenu* menu = [NSMenu new];
	[menu setAutoenablesItems:NO];

	[menu addItemWithTitle:@"New Tab"                 action:@selector(takeNewTabIndexFrom:)  keyEquivalent:@""];
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItemWithTitle:@"Close Tab"               action:closeSingleTabSelector           keyEquivalent:@""];
	[menu addItemWithTitle:@"Close Other Tabs"        action:@selector(takeTabsToCloseFrom:)  keyEquivalent:@""];
	[menu addItemWithTitle:@"Close Tabs to the Right" action:@selector(takeTabsToCloseFrom:)  keyEquivalent:@""];
	[menu addItem:[NSMenuItem separatorItem]];
	[menu addItemWithTitle:@"Move Tab to New Window"  action:@selector(takeTabsToTearOffFrom:) keyEquivalent:@""];

	NSIndexSet* indexSets[] = { newTabAtTab, nil, clickedTab, otherTabs, rightSideTabs, nil, total > 1 ? clickedTab : [NSIndexSet indexSet] };
	for(size_t i = 0; i < sizeofA(indexSets); ++i)
	{
		if(NSIndexSet* indexSet = indexSets[i])
		{
			if([indexSet count] == 0)
					[[menu itemAtIndex:i] setEnabled:NO];
			else	[[menu itemAtIndex:i] setRepresentedObject:indexSet];
		}
	}

	return menu;
}

// =========================
// = OakTabBarViewDelegate =
// =========================

- (BOOL)tabBarView:(OakTabBarView*)aTabBarView shouldSelectIndex:(NSUInteger)anIndex
{
	[self openAndSelectDocument:[self documents][anIndex]];
	self.selectedTabIndex = anIndex;
	return YES;
}

- (void)tabBarView:(OakTabBarView*)aTabBarView didDoubleClickIndex:(NSUInteger)anIndex
{
	if(self.documents.size() > 1)
		[self takeTabsToTearOffFrom:[NSMutableIndexSet indexSetWithIndex:anIndex]];
}

- (void)tabBarViewDidDoubleClick:(OakTabBarView*)aTabBarView
{
	[self takeNewTabIndexFrom:[NSMutableIndexSet indexSetWithIndex:self.documents.size()]];
}

// ================
// = Tab Dragging =
// ================

- (void)setupPasteboard:(NSPasteboard*)aPasteboard forTabAtIndex:(NSUInteger)draggedTabIndex
{
	document::document_ptr document = [self documents][draggedTabIndex];
	if(document->path() != NULL_STR)
	{
		[aPasteboard addTypes:@[ NSFilenamesPboardType ] owner:nil];
		[aPasteboard setPropertyList:@[ [NSString stringWithCxxString:document->path()] ] forType:NSFilenamesPboardType];
	}

	[aPasteboard addTypes:@[ OakDocumentPboardType ] owner:nil];
	[aPasteboard setPropertyList:@{
		@"index"       : @(draggedTabIndex),
		@"document"    : [NSString stringWithCxxString:document->identifier()],
		@"collection"  : self.identifier,
	} forType:OakDocumentPboardType];
}

- (BOOL)performTabDropFromTabBar:(OakTabBarView*)aTabBar atIndex:(NSUInteger)droppedIndex fromPasteboard:(NSPasteboard*)aPasteboard operation:(NSDragOperation)operation
{
	NSDictionary* plist = [aPasteboard propertyListForType:OakDocumentPboardType];
	oak::uuid_t docId   = to_s((NSString*)plist[@"document"]);

	std::vector<document::document_ptr> newDocuments;
	merge_documents_splitting_at(self.documents, make_vector(document::find(docId)), droppedIndex, newDocuments);
	self.documents = newDocuments;

	oak::uuid_t selectedUUID = [self selectedDocument]->identifier();
	auto iter = std::find_if(newDocuments.begin(), newDocuments.end(), [&selectedUUID](document::document_ptr const& doc){ return doc->identifier() == selectedUUID; });
	if(iter != newDocuments.end())
		self.selectedTabIndex = iter - newDocuments.begin();

	oak::uuid_t srcProjectId = to_s((NSString*)plist[@"collection"]);
	if(operation == NSDragOperationMove && srcProjectId != to_s(self.identifier))
	{
		for(NSWindow* window in [NSApp orderedWindows])
		{
			DocumentController* delegate = (DocumentController*)[window delegate];
			if([delegate isKindOfClass:[DocumentController class]] && srcProjectId == oak::uuid_t(to_s(delegate.identifier)))
				return [delegate closeTabsAtIndexes:[NSIndexSet indexSetWithIndex:[plist[@"index"] unsignedIntValue]] askToSaveChanges:NO createDocumentIfEmpty:YES], YES;
		}
	}

	return YES;
}

- (IBAction)selectNextTab:(id)sender            { self.selectedTabIndex = (_selectedTabIndex + 1) % _documents.size();                     [self openAndSelectDocument:_documents[_selectedTabIndex]]; }
- (IBAction)selectPreviousTab:(id)sender        { self.selectedTabIndex = (_selectedTabIndex + _documents.size() - 1) % _documents.size(); [self openAndSelectDocument:_documents[_selectedTabIndex]]; }
- (IBAction)takeSelectedTabIndexFrom:(id)sender { self.selectedTabIndex = [[OakSubmenuController sharedInstance] tagForSender:sender];     [self openAndSelectDocument:_documents[_selectedTabIndex]]; }

// ==================
// = OakFileBrowser =
// ==================

- (void)fileBrowser:(OakFileBrowser*)aFileBrowser openURLs:(NSArray*)someURLs
{
	NSMutableArray* items = [NSMutableArray array];
	for(NSURL* url in someURLs)
	{
		if([url isFileURL])
			[items addObject:@{ @"path" : [url path] }];
	}
	[self openItems:items closingOtherTabs:OakIsAlternateKeyOrMouseEvent()];
}

- (void)fileBrowser:(OakFileBrowser*)aFileBrowser closeURL:(NSURL*)anURL
{
	if(![anURL isFileURL])
		return;

	std::string const path = to_s([anURL path]);
	auto documents = self.documents;
	NSMutableIndexSet* indexSet = [NSMutableIndexSet indexSet];
	for(size_t i = 0; i < documents.size(); ++i)
	{
		if(path == documents[i]->path())
			[indexSet addIndex:i];
	}
	[self closeTabsAtIndexes:indexSet askToSaveChanges:YES createDocumentIfEmpty:YES];
}

- (void)setFileBrowserVisible:(BOOL)makeVisibleFlag
{
	if(_fileBrowserVisible != makeVisibleFlag)
	{
		_fileBrowserVisible = makeVisibleFlag;
		if(!self.fileBrowser && makeVisibleFlag)
		{
			self.fileBrowser = [OakFileBrowser new];
			self.fileBrowser.delegate = self;
			[self.fileBrowser setupViewWithState:_fileBrowserHistory];
			if(self.projectPath && !_fileBrowserHistory)
				[self.fileBrowser showURL:[NSURL fileURLWithPath:self.projectPath]];
			[self updateFileBrowserStatus:self];
		}
		self.layoutView.fileBrowserView = makeVisibleFlag ? self.fileBrowser.view : nil;
	}
	document::schedule_session_backup();
}

- (IBAction)toggleFileBrowser:(id)sender    { self.fileBrowserVisible = !self.fileBrowserVisible; }

- (void)updateFileBrowserStatus:(id)sender
{
	NSMutableArray* openURLs     = [NSMutableArray array];
	NSMutableArray* modifiedURLs = [NSMutableArray array];
	citerate(document, self.documents)
	{
		if((*document)->path() != NULL_STR)
			[openURLs addObject:[NSURL fileURLWithPath:[NSString stringWithCxxString:(*document)->path()]]];
		if((*document)->path() != NULL_STR && (*document)->is_modified())
			[modifiedURLs addObject:[NSURL fileURLWithPath:[NSString stringWithCxxString:(*document)->path()]]];
	}
	self.fileBrowser.openURLs     = openURLs;
	self.fileBrowser.modifiedURLs = modifiedURLs;
}

- (NSDictionary*)fileBrowserHistory         { return self.fileBrowser.sessionState ?: _fileBrowserHistory; }
- (CGFloat)fileBrowserWidth                 { return self.layoutView.fileBrowserWidth;   }
- (void)setFileBrowserWidth:(CGFloat)aWidth { self.layoutView.fileBrowserWidth = aWidth; }

- (IBAction)revealFileInProject:(id)sender                     { self.fileBrowserVisible = YES; [self.fileBrowser showURL:[NSURL fileURLWithPath:[NSString stringWithCxxString:[self selectedDocument]->path()]]]; }
- (IBAction)revealFileInProjectByExpandingAncestors:(id)sender { self.fileBrowserVisible = YES; [self.fileBrowser revealURL:[NSURL fileURLWithPath:[NSString stringWithCxxString:[self selectedDocument]->path()]]]; }

- (IBAction)goToProjectFolder:(id)sender    { self.fileBrowserVisible = YES; [self.fileBrowser showURL:[NSURL fileURLWithPath:self.projectPath]]; }

- (IBAction)goBack:(id)sender               { self.fileBrowserVisible = YES; [NSApp sendAction:_cmd to:self.fileBrowser from:sender]; }
- (IBAction)goForward:(id)sender            { self.fileBrowserVisible = YES; [NSApp sendAction:_cmd to:self.fileBrowser from:sender]; }
- (IBAction)goToParentFolder:(id)sender     { self.fileBrowserVisible = YES; [NSApp sendAction:_cmd to:self.fileBrowser from:sender]; }

- (IBAction)goToComputer:(id)sender         { self.fileBrowserVisible = YES; [NSApp sendAction:_cmd to:self.fileBrowser from:sender]; }
- (IBAction)goToHome:(id)sender             { self.fileBrowserVisible = YES; [NSApp sendAction:_cmd to:self.fileBrowser from:sender]; }
- (IBAction)goToDesktop:(id)sender          { self.fileBrowserVisible = YES; [NSApp sendAction:_cmd to:self.fileBrowser from:sender]; }
- (IBAction)goToFavorites:(id)sender        { self.fileBrowserVisible = YES; [NSApp sendAction:_cmd to:self.fileBrowser from:sender]; }
- (IBAction)goToSCMDataSource:(id)sender    { self.fileBrowserVisible = YES; [NSApp sendAction:_cmd to:self.fileBrowser from:sender]; }
- (IBAction)orderFrontGoToFolder:(id)sender { self.fileBrowserVisible = YES; [NSApp sendAction:_cmd to:self.fileBrowser from:sender]; }

// ===============
// = HTML Output =
// ===============

- (NSSize)htmlOutputSize                    { return self.layoutView.htmlOutputSize;  }
- (void)setHtmlOutputSize:(NSSize)aSize     { self.layoutView.htmlOutputSize = aSize; }

- (BOOL)htmlOutputVisible
{
	return self.layoutView.htmlOutputView || [self.htmlOutputWindowController.window isVisible];
}

- (void)setHtmlOutputVisible:(BOOL)makeVisibleFlag
{
	if(self.htmlOutputVisible == makeVisibleFlag)
		return;

	if(makeVisibleFlag)
	{
		if(self.htmlOutputInWindow)
		{
			[self.htmlOutputWindowController.window makeKeyAndOrderFront:self];
		}
		else
		{
			if(!self.htmlOutputView)
				self.htmlOutputView = [[OakHTMLOutputView alloc] initWithFrame:NSZeroRect];
			self.layoutView.htmlOutputView = self.htmlOutputView;
		}
	}
	else
	{
		[self.htmlOutputWindowController.window orderOut:self];
		self.layoutView.htmlOutputView = nil;
	}
}

- (void)setHtmlOutputInWindow:(BOOL)showInWindowFlag
{
	if(_htmlOutputInWindow == showInWindowFlag)
		return;

	if(_htmlOutputInWindow = showInWindowFlag)
	{
		self.layoutView.htmlOutputView = nil;
		self.htmlOutputView = nil;
	}
	else
	{
		self.htmlOutputWindowController = nil;
	}
}

- (IBAction)toggleHTMLOutput:(id)sender
{
	self.htmlOutputVisible = !self.htmlOutputVisible;
}

- (BOOL)setCommandRunner:(command::runner_ptr const&)aRunner
{
	if(self.htmlOutputInWindow)
	{
		_runner = aRunner;

		if(!self.htmlOutputWindowController || [self.htmlOutputWindowController running])
				self.htmlOutputWindowController = [HTMLOutputWindowController HTMLOutputWindowWithRunner:_runner];
		else	[self.htmlOutputWindowController setCommandRunner:_runner];
	}
	else
	{
		if(_runner && _runner->running())
		{
			NSInteger choice = [[NSAlert alertWithMessageText:@"Stop current task first?" defaultButton:@"Stop Task" alternateButton:@"Cancel" otherButton:nil informativeTextWithFormat:@"There already is a task running. If you stop this then the task it is performing will not be completed."] runModal];
			if(choice != NSAlertDefaultReturn) /* "Stop" */
				return NO;
		}

		_runner = aRunner;

		self.htmlOutputVisible = YES;
		[self.window makeFirstResponder:self.htmlOutputView.webView];
		[self.htmlOutputView setEnvironment:_runner->environment()];
		[self.htmlOutputView loadRequest:URLRequestForCommandRunner(_runner) autoScrolls:_runner->auto_scroll_output()];
	}
	return YES;
}

// =============================
// = Opening Auxiliary Windows =
// =============================

- (void)setFilterWindowController:(OakFilterWindowController*)controller
{
	if(_filterWindowController != controller)
	{
		if(_filterWindowController)
		{
			if(self.fileChooserSourceIndex == NSNotFound)
				self.fileChooserSourceIndex = [self.filterWindowController.dataSource sourceIndex];
			[[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowWillCloseNotification object:_filterWindowController.window];
			_filterWindowController.target = nil;
			[_filterWindowController close];
		}

		if(_filterWindowController = controller)
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(filterWindowWillClose:) name:NSWindowWillCloseNotification object:_filterWindowController.window];
	}
}

- (void)filterWindowWillClose:(NSNotification*)notification
{
	self.filterWindowController = nil;
}

- (IBAction)orderFrontFindPanel:(id)sender
{
	Find* find              = [Find sharedInstance];
	find.documentIdentifier = [NSString stringWithCxxString:[self selectedDocument]->identifier()];
	find.projectFolder      = self.projectPath ?: self.untitledSavePath ?: NSHomeDirectory();
	find.projectIdentifier  = self.identifier;

	NSInteger mode = [sender respondsToSelector:@selector(tag)] ? [sender tag] : find_tags::in_document;
	if(mode == find_tags::in_folder)
		return [find showFolderSelectionPanel:self];

	if(mode == find_tags::in_document && self.textView.hasMultiLineSelection)
		mode = find_tags::in_selection;

	switch(mode)
	{
		case find_tags::in_document:
			find.searchScope = find::in::document;
		break;

		case find_tags::in_selection:
			find.searchScope = find::in::selection;
		break;

		case find_tags::in_project:
		{
			find.searchScope = find::in::folder;
			if(!find.isVisible)
			{
				BOOL fileBrowserHasFocus = [self.window.firstResponder respondsToSelector:@selector(isDescendantOf:)] && [(NSView*)self.window.firstResponder isDescendantOf:self.fileBrowser.view];
				find.searchFolder = fileBrowserHasFocus ? self.untitledSavePath : find.projectFolder;
			}
		}
		break;
	}
	[find showFindPanel:self];
}

- (IBAction)showSymbolChooser:(id)sender
{
	self.filterWindowController                         = [OakFilterWindowController filterWindow];
	self.filterWindowController.dataSource              = [SymbolChooser symbolChooserForDocument:[self selectedDocument]];
	self.filterWindowController.action                  = @selector(symbolChooserDidSelectItems:);
	self.filterWindowController.sendActionOnSingleClick = YES;
	[self.filterWindowController showWindowRelativeToWindow:self.window];
}

- (void)symbolChooserDidSelectItems:(id)sender
{
	[self openItems:[sender selectedItems] closingOtherTabs:NO];
}

// ==================
// = OakFileChooser =
// ==================

static std::string file_chooser_glob (std::string const& path)
{
	settings_t const& settings = settings_for_path(NULL_STR, "", path);
	std::string const propertyKeys[] = { kSettingsIncludeFilesInFileChooserKey, kSettingsIncludeInFileChooserKey, kSettingsIncludeFilesKey, kSettingsIncludeKey };
	iterate(key, propertyKeys)
	{
		if(settings.has(*key))
			return settings.get(*key, NULL_STR);
	}
	return "*";
}

- (IBAction)goToFile:(id)sender
{
	self.filterWindowController = [OakFilterWindowController filterWindow];

	OakFileChooser* dataSource = [OakFileChooser fileChooserWithPath:(self.fileBrowser.location ?: [NSString stringWithCxxString:[self selectedDocument]->path()] ?: self.projectPath ?: NSHomeDirectory()) projectPath:self.projectPath ?: NSHomeDirectory()];
	dataSource.excludeDocumentWithIdentifier = [NSString stringWithCxxString:[self selectedDocument]->identifier()];
	dataSource.sourceIndex                   = self.fileChooserSourceIndex;
	dataSource.globString                    = [NSString stringWithCxxString:file_chooser_glob(to_s(dataSource.path))];

	if(OakPasteboardEntry* entry = [[OakPasteboard pasteboardWithName:NSFindPboard] current])
	{
		std::string str = [entry.string UTF8String] ?: "";
		if(regexp::search("\\A.*?\\..*?:\\d+\\z", str.data(), str.data() + str.size()))
			dataSource.filterString = entry.string;
	}

	self.filterWindowController.dataSource              = dataSource;
	self.filterWindowController.target                  = self;
	self.filterWindowController.allowsMultipleSelection = YES;
	self.filterWindowController.action                  = @selector(fileChooserDidSelectItems:);
	self.filterWindowController.accessoryAction         = @selector(fileChooserDidDescend:);
	self.fileChooserSourceIndex = NSNotFound;
	[self.filterWindowController showWindowRelativeToWindow:self.window];
}

- (void)fileChooserDidSelectItems:(OakFilterWindowController*)sender
{
	[self openItems:[sender selectedItems] closingOtherTabs:OakIsAlternateKeyOrMouseEvent()];
}

- (void)fileChooserDidDescend:(id)sender
{
	ASSERT([sender respondsToSelector:@selector(selectedItems)]);
	ASSERT([[sender selectedItems] count] == 1);

	NSString* documentIdentifier = [[[sender selectedItems] lastObject] objectForKey:@"identifier"];
	self.fileChooserSourceIndex = [self.filterWindowController.dataSource sourceIndex];
	self.filterWindowController.dataSource              = [SymbolChooser symbolChooserForDocument:document::find(to_s(documentIdentifier))];
	self.filterWindowController.action                  = @selector(symbolChooserDidSelectItems:);
	self.filterWindowController.sendActionOnSingleClick = YES;
}

// ===========
// = Methods =
// ===========

- (NSString*)untitledSavePath
{
	NSString* res = self.projectPath;
	if(self.fileBrowserVisible)
	{
		NSArray* selectedURLs = self.fileBrowser.selectedURLs;
		if([selectedURLs count] == 1 && [[selectedURLs lastObject] isFileURL] && path::is_directory([[[selectedURLs lastObject] path] fileSystemRepresentation]))
			res = [[selectedURLs lastObject] path];
		else if(NSString* folder = self.fileBrowser.location)
			res = folder;
	}
	return res;
}

- (NSPoint)positionForWindowUnderCaret
{
	return [self.textView positionForWindowUnderCaret];
}

- (void)performBundleItem:(bundles::item_ptr const&)anItem
{
	if(anItem->kind() == bundles::kItemTypeTheme)
	{
		[self.documentView setThemeWithUUID:[NSString stringWithCxxString:anItem->uuid()]];
	}
	else
	{
		[self showWindow:self];
		[self makeTextViewFirstResponder:self];
		[self.textView performBundleItem:anItem];
	}
}

- (IBAction)goToFileCounterpart:(id)sender
{
	std::string const documentPath = [self selectedDocument]->path();
	if(documentPath == NULL_STR)
		return (void)NSBeep();

	std::string const documentDir  = path::parent(documentPath);
	std::string const documentName = path::name(documentPath);
	std::string const documentBase = path::strip_extensions(documentName);

	std::set<std::string> candidates(&documentName, &documentName + 1);
	citerate(doc, self.documents)
	{
		if(documentDir == path::parent((*doc)->path()) && documentBase == path::strip_extensions(path::name((*doc)->path())))
			candidates.insert(path::name((*doc)->path()));
	}

	citerate(entry, path::entries(documentDir))
	{
		std::string const name = (*entry)->d_name;
		if((*entry)->d_type == DT_REG && documentBase == path::strip_extensions(name) && path::extensions(name) != "")
		{
			std::string const content = path::content(path::join(documentDir, name));
			if(utf8::is_valid(content.data(), content.data() + content.size()))
				candidates.insert(name);
		}
	}

	settings_t const settings = [self selectedDocument]->settings();
	path::glob_t const excludeGlob(settings.get(kSettingsExcludeKey, ""));
	path::glob_t const binaryGlob(settings.get(kSettingsBinaryKey, ""));

	std::vector<std::string> v;
	iterate(path, candidates)
	{
		if(*path == documentPath || !binaryGlob.does_match(*path) && !excludeGlob.does_match(*path))
			v.push_back(*path);
	}

	if(v.size() == 1)
		return (void)NSBeep();

	std::vector<std::string>::const_iterator it = std::find(v.begin(), v.end(), documentName);
	ASSERT(it != v.end());

	NSString* path = [NSString stringWithCxxString:path::join(documentDir, v[((it - v.begin()) + 1) % v.size()])];
	[self openItems:@[ @{ @"path" : path } ] closingOtherTabs:NO];
}

// ===========================
// = Go to Tab Menu Delegate =
// ===========================

- (void)updateGoToMenu:(NSMenu*)aMenu
{
	if(![self.window isKeyWindow])
	{
		[aMenu addItemWithTitle:@"No Tabs" action:@selector(nop:) keyEquivalent:@""];
		return;
	}

	int i = 0;
	citerate(document, self.documents)
	{
		NSMenuItem* item = [aMenu addItemWithTitle:[NSString stringWithCxxString:(*document)->display_name()] action:@selector(takeSelectedTabIndexFrom:) keyEquivalent:i < 10 ? [NSString stringWithFormat:@"%c", '0' + ((i+1) % 10)] : @""];
		item.tag = i;
		item.toolTip = [[NSString stringWithCxxString:(*document)->path()] stringByAbbreviatingWithTildeInPath];
		if(i == self.selectedTabIndex)
			[item setState:NSOnState];
		else if((*document)->is_modified())
			[item setModifiedState:YES];
		++i;
	}

	if(i == 0)
		[aMenu addItemWithTitle:@"No Tabs Open" action:@selector(nop:) keyEquivalent:@""];
}

// ====================
// = NSMenuValidation =
// ====================

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem;
{
	BOOL active = YES;
	if([menuItem action] == @selector(toggleFileBrowser:))
		[menuItem setTitle:self.fileBrowserVisible ? @"Hide File Browser" : @"Show File Browser"];
	else if([menuItem action] == @selector(toggleHTMLOutput:))
	{
		[menuItem setTitle:self.htmlOutputVisible ? @"Hide HTML Output" : @"Show HTML Output"];
		active = !self.htmlOutputInWindow || self.htmlOutputWindowController;
	}
	else if([menuItem action] == @selector(moveDocumentToNewWindow:))
		active = self.documents.size() > 1;
	else if([menuItem action] == @selector(revealFileInProject:) || [menuItem action] == @selector(revealFileInProjectByExpandingAncestors:))
		active = [self selectedDocument]->path() != NULL_STR;
	else if([menuItem action] == @selector(goToProjectFolder:))
		active = self.projectPath != nil;
	else if([menuItem action] == @selector(goToParentFolder:))
		active = [self.window firstResponder] != self.textView;
	return active;
}

// ======================
// = Session Management =
// ======================

+ (void)windowNotificationActual:(id)sender
{
	document::schedule_session_backup();
}

+ (void)windowNotification:(NSNotification*)aNotification
{
	[self performSelector:@selector(windowNotificationActual:) withObject:nil afterDelay:0]; // A deadlock happens if we receive a notification while a sheet is closing and we save session (since session saving schedules a timer with the run loop, and the run loop is in a special state when a sheet is up, or something like that --Allan)
}

+ (void)initialize
{
	static NSString* const WindowNotifications[] = { NSWindowDidBecomeKeyNotification, NSWindowDidDeminiaturizeNotification, NSWindowDidExposeNotification, NSWindowDidMiniaturizeNotification, NSWindowDidMoveNotification, NSWindowDidResizeNotification, NSWindowWillCloseNotification };
	iterate(notification, WindowNotifications)
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowNotification:) name:*notification object:nil];
}

// ==========
// = Legacy =
// ==========

- (void)updateVariables:(std::map<std::string, std::string>&)env
{
	[self.fileBrowser updateVariables:env];

	if(NSString* projectDir = self.projectPath)
	{
		env["TM_PROJECT_DIRECTORY"] = [projectDir fileSystemRepresentation];
		env["TM_PROJECT_UUID"]      = to_s(self.identifier);
	}

	if(auto theme = self.textView.theme)
	{
		if(auto themeItem = bundles::lookup(theme->uuid()))
		{
			if(!themeItem->paths().empty())
				env["TM_CURRENT_THEME_PATH"] = themeItem->paths().back();
		}
	}
}

+ (instancetype)controllerForDocument:(document::document_ptr const&)aDocument
{
	if(!aDocument)
		return nil;

	for(NSWindow* window in [NSApp orderedWindows])
	{
		DocumentController* controller = (DocumentController*)[window delegate];
		if([controller isKindOfClass:self])
		{
			if(controller.fileBrowserVisible && aDocument->path() != NULL_STR && aDocument->path().find(to_s(controller.projectPath)) == 0)
				return controller;

			citerate(document, controller.documents)
			{
				if(**document == *aDocument)
					return controller;
			}
		}
	}
	return nil;
}

+ (void)load
{
	static struct proxy_t : document::ui_proxy_t
	{
	private:
		static void bring_to_front (DocumentController* aController)
		{
			if([NSApp isHidden])
			{
				__block id observerId = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidUnhideNotification object:NSApp queue:nil usingBlock:^(NSNotification*){
					[aController showWindow:nil];
					SetFrontProcessWithOptions(&(ProcessSerialNumber){ 0, kCurrentProcess }, kSetFrontProcessFrontWindowOnly);
					[[NSNotificationCenter defaultCenter] removeObserver:observerId];
				}];
				[NSApp unhideWithoutActivation];
			}
			else
			{
				[aController showWindow:nil];
				SetFrontProcessWithOptions(&(ProcessSerialNumber){ 0, kCurrentProcess }, kSetFrontProcessFrontWindowOnly);
			}
		}

		mutable NSMutableDictionary* _controllers = [NSMutableDictionary new];

		NSArray* sorted_controllers () const
		{
			NSMutableArray* res = [NSMutableArray array];
			for(NSNumber* flag in @[ @NO, @YES ])
			{
				for(NSWindow* window in [NSApp orderedWindows])
				{
					if([window isMiniaturized] == [flag boolValue] && [window.delegate respondsToSelector:@selector(identifier)])
					{
						DocumentController* delegate = (DocumentController*)window.delegate;
						if(id controller = _controllers[delegate.identifier])
							[res addObject:controller];
					}
				}
			}
			return res;
		}

		void monitor_controller (DocumentController* controller) const
		{
			NSString* identifier = controller.identifier;
			_controllers[identifier] = controller;

			__block id observerId = [[NSNotificationCenter defaultCenter] addObserverForName:OakDocumentWindowWillCloseNotification object:controller queue:nil usingBlock:^(NSNotification* notification){
				[_controllers removeObjectForKey:identifier];
				[[NSNotificationCenter defaultCenter] removeObserver:observerId];
			}];
		}

	public:
		void show_documents (std::vector<document::document_ptr> const& documents, std::string const& browserPath) const
		{
			DocumentController* controller = nil;
			if(browserPath != NULL_STR)
			{
				ASSERT(documents.empty());
				std::string const folder = path::resolve(browserPath);

				for(DocumentController* candidate in sorted_controllers())
				{
					if(folder == to_s(candidate.projectPath))
						return bring_to_front(candidate);
				}

				for(DocumentController* candidate in sorted_controllers())
				{
					if(candidate.fileBrowserVisible || candidate.documents.size() != 1 || !is_disposable(candidate.selectedDocument))
						continue;

					controller = candidate;
					break;
				}

				if(!controller)
				{
					controller = [DocumentController new];
					monitor_controller(controller);
				}
				else if(controller.selectedDocument)
				{
					[controller selectedDocument]->set_custom_name("not untitled"); // release potential untitled token used
				}

				controller.defaultProjectPath = [NSString stringWithCxxString:folder];
				controller.fileBrowserVisible = YES;
				controller.documents          = make_vector(create_untitled_document_in_folder(folder));
				[controller.fileBrowser showURL:[NSURL fileURLWithPath:[NSString stringWithCxxString:folder]]];
			}
			else if(!documents.empty())
			{
				for(DocumentController* candidate in sorted_controllers())
				{
					std::string const projectPath     = to_s(candidate.projectPath);
					std::string const fileBrowserPath = candidate.fileBrowserVisible ? to_s(candidate.fileBrowser.location) : NULL_STR;

					iterate(document, documents)
					{
						std::string const docPath = (*document)->path();
						if(docPath.find(projectPath) == 0 || (fileBrowserPath != NULL_STR && docPath.find(fileBrowserPath) == 0))
							controller = candidate;

						citerate(projectDoc, candidate.documents)
						{
							if((*document)->identifier() == (*projectDoc)->identifier())
								controller = candidate;
						}
					}

					if(!controller && !candidate.fileBrowserVisible && candidate.documents.size() == 1 && is_disposable(candidate.selectedDocument))
						controller = candidate;

					if(controller)
						break;
				}

				if(controller)
				{
					std::vector<document::document_ptr> oldDocuments = controller.documents;
					NSUInteger split = controller.selectedTabIndex;

					if(!oldDocuments.empty() && is_disposable(oldDocuments[split]))
							oldDocuments.erase(oldDocuments.begin() + split);
					else	++split;

					std::vector<document::document_ptr> newDocuments;
					split = merge_documents_splitting_at(oldDocuments, documents, split, newDocuments);
					controller.documents = newDocuments;
					controller.selectedTabIndex = split;
				}
				else
				{
					controller = [DocumentController new];
					monitor_controller(controller);
					controller.documents = documents;

					std::string projectPath = NULL_STR;
					iterate(document, documents)
					{
						std::string const path = path::parent((*document)->path());
						if(path != NULL_STR && (projectPath == NULL_STR || path.size() < projectPath.size()))
							projectPath = path;
					}

					if(projectPath != NULL_STR)
						controller.defaultProjectPath = [NSString stringWithCxxString:projectPath];
				}
			}
			else
			{
				ASSERT(browserPath != NULL_STR || !documents.empty());
				return;
			}

			[controller openAndSelectDocument:[controller documents][controller.selectedTabIndex]];
			bring_to_front(controller);
		}

		void show_document (oak::uuid_t const& collection, document::document_ptr document, text::range_t const& range, bool bringToFront) const
		{
			if(range != text::range_t::undefined)
				document->set_selection(range);

			NSString* projectId = [NSString stringWithCxxString:collection];
			DocumentController* controller = _controllers[projectId];
			if(collection == document::kCollectionCurrent)
				controller = [sorted_controllers() firstObject];

			if(controller)
			{
				std::vector<document::document_ptr> oldDocuments = controller.documents;
				NSUInteger split = controller.selectedTabIndex;

				if(!oldDocuments.empty() && is_disposable(oldDocuments[split]))
						oldDocuments.erase(oldDocuments.begin() + split);
				else	++split;

				std::vector<document::document_ptr> newDocuments;
				split = merge_documents_splitting_at(oldDocuments, make_vector(document), split, newDocuments);
				controller.documents = newDocuments;
				controller.selectedTabIndex = split;
			}
			else
			{
				controller = [DocumentController new];
				controller.documents = make_vector(document);
				if(collection != document::kCollectionCurrent && collection != document::kCollectionNew)
					controller.identifier = projectId;
				monitor_controller(controller);
			}

			if(bringToFront)
				bring_to_front(controller);
			else if(![controller.window isVisible])
				[controller.window orderWindow:NSWindowBelow relativeTo:[([NSApp keyWindow] ?: [NSApp mainWindow]) windowNumber]];

			[controller openAndSelectDocument:document];
		}

		void run (bundle_command_t const& command, ng::buffer_t const& buffer, ng::ranges_t const& selection, document::document_ptr document, std::map<std::string, std::string> const& env, document::run_callback_ptr callback)
		{
			::run(command, buffer, selection, document, env, callback);
		}

		bool load_session (std::string const& path) const
		{
			bool res = false;
			plist::dictionary_t session = plist::load(path);
			plist::array_t projects;
			if(plist::get_key_path(session, "projects", projects))
			{
				iterate(project, projects)
				{
					NSInteger selectedTabIndex = 0;
					std::vector<document::document_ptr> documents;
					plist::array_t docsArray;
					if(plist::get_key_path(*project, "documents", docsArray))
					{
						iterate(document, docsArray)
						{
							document::document_ptr doc;
							std::string str;
							if(plist::get_key_path(*document, "identifier", str) && (doc = document::find(oak::uuid_t(str))))
								documents.push_back(doc);
							else if(plist::get_key_path(*document, "path", str))
								documents.push_back(document::create(str));
							else if(plist::get_key_path(*document, "displayName", str))
							{
								documents.push_back(document::create()); // TODO Should use create_untitled_document_in_folder(«projectFolder»)
								documents.back()->set_custom_name(str);
							}
							else
								continue;

							documents.back()->set_recent_tracking(false);

							bool flag;
							if(plist::get_key_path(*document, "selected", flag) && flag)
								selectedTabIndex = documents.size() - 1;
						}
					}

					if(documents.empty())
						documents.push_back(document::create());

					DocumentController* controller = [DocumentController new];
					monitor_controller(controller);

					std::string projectPath = NULL_STR;
					if(plist::get_key_path(*project, "projectPath", projectPath))
						controller.defaultProjectPath = [NSString stringWithCxxString:projectPath];

					controller.documents = documents;
					controller.selectedTabIndex = selectedTabIndex;
					[controller openAndSelectDocument:documents[selectedTabIndex]];

					plist::dictionary_t fileBrowserState;
					if(plist::get_key_path(*project, "fileBrowserState", fileBrowserState))
						controller.fileBrowserHistory = ns::to_dictionary(fileBrowserState);

					CGFloat size;
					if(plist::get_key_path(*project, "fileBrowserWidth", size))
						controller.fileBrowserWidth = size;

					std::string str;
					if(plist::get_key_path(*project, "htmlOutputSize", str))
						controller.htmlOutputSize = NSSizeFromString([NSString stringWithCxxString:str]);

					std::string windowFrame = NULL_STR;
					if(plist::get_key_path(*project, "windowFrame", windowFrame))
						[controller.window setFrame:NSRectFromString([NSString stringWithCxxString:windowFrame]) display:NO];

					bool fileBrowserVisible = false;
					if(plist::get_key_path(*project, "fileBrowserVisible", fileBrowserVisible) && fileBrowserVisible)
						controller.fileBrowserVisible = YES;

					[controller showWindow:nil];

					bool isMiniaturized = false;
					if(plist::get_key_path(*project, "miniaturized", isMiniaturized) && isMiniaturized)
						[controller.window miniaturize:nil];

					res = true;
				}
			}

			return res;
		}

		bool save_session (std::string const& path, bool includeUntitled) const
		{
			plist::array_t projects;
			for(NSWindow* window in [[[NSApp orderedWindows] reverseObjectEnumerator] allObjects])
			{
				DocumentController* controller = (DocumentController*)[window delegate];
				if([controller isKindOfClass:[DocumentController class]])
				{
					plist::dictionary_t res;

					res["projectPath"]        = to_s(controller.defaultProjectPath);
					res["windowFrame"]        = to_s(NSStringFromRect([controller.window frame]));
					res["miniaturized"]       = [controller.window isMiniaturized];
					res["htmlOutputSize"]     = to_s(NSStringFromSize(controller.htmlOutputSize));
					res["fileBrowserVisible"] = controller.fileBrowserVisible;
					res["fileBrowserWidth"]   = (int32_t)controller.fileBrowserWidth;

					if(CFDictionaryRef fbState = (CFDictionaryRef)CFBridgingRetain(controller.fileBrowserHistory))
					{
						res["fileBrowserState"] = plist::convert(fbState);
						CFRelease(fbState);
					}

					plist::array_t docs;
					citerate(document, controller.documents)
					{
						if(!includeUntitled && ((*document)->path() == NULL_STR || !path::exists((*document)->path())))
							continue;

						plist::dictionary_t doc;
						if((*document)->is_modified() || (*document)->path() == NULL_STR)
						{
							doc["identifier"] = std::string((*document)->identifier());
							if((*document)->is_open())
								(*document)->backup();
						}
						if((*document)->path() != NULL_STR)
							doc["path"] = (*document)->path();
						if((*document)->display_name() != NULL_STR)
							doc["displayName"] = (*document)->display_name();
						if(*document == controller.selectedDocument)
							doc["selected"] = true;
						docs.push_back(doc);
					}
					res["documents"] = docs;

					if(!docs.empty())
						projects.push_back(res);
				}
			}

			plist::dictionary_t session;
			session["projects"] = projects;
			return plist::save(path, session);
		}

	} proxy;

	document::set_ui_proxy(&proxy);
}
@end
