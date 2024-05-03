import Foundation
import TelegramPresentationData
import AccountContext
import Postbox
import TelegramCore
import SwiftSignalKit
import Display
import TelegramPresentationData
import PresentationDataUtils
import UndoUI
import AdminUserActionsSheet
import ContextUI
import TelegramStringFormatting
import StorageUsageScreen
import SettingsUI
import DeleteChatPeerActionSheetItem
import OverlayStatusController

fileprivate struct InitialBannedRights {
    var value: TelegramChatBannedRights?
}

extension ChatControllerImpl {
    fileprivate func applyAdminUserActionsResult(messageIds: Set<MessageId>, result: AdminUserActionsSheet.Result, initialUserBannedRights: [EnginePeer.Id: InitialBannedRights]) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        
        var title: String? = messageIds.count == 1 ? self.presentationData.strings.Chat_AdminAction_ToastMessagesDeletedTitleSingle : self.presentationData.strings.Chat_AdminAction_ToastMessagesDeletedTitleMultiple
        if !result.deleteAllFromPeers.isEmpty {
            title = self.presentationData.strings.Chat_AdminAction_ToastMessagesDeletedTitleMultiple
        }
        var text: String = ""
        var undoRights: [EnginePeer.Id: InitialBannedRights] = [:]
        
        if !result.reportSpamPeers.isEmpty {
            if !text.isEmpty {
                text.append("\n")
            }
            text.append(self.presentationData.strings.Chat_AdminAction_ToastReportedSpamText(Int32(result.reportSpamPeers.count)))
        }
        if !result.banPeers.isEmpty {
            if !text.isEmpty {
                text.append("\n")
            }
            text.append(self.presentationData.strings.Chat_AdminAction_ToastBannedText(Int32(result.banPeers.count)))
            for id in result.banPeers {
                if let value = initialUserBannedRights[id] {
                    undoRights[id] = value
                }
            }
        }
        if !result.updateBannedRights.isEmpty {
            if !text.isEmpty {
                text.append("\n")
            }
            text.append(self.presentationData.strings.Chat_AdminAction_ToastRestrictedText(Int32(result.updateBannedRights.count)))
            for (id, _) in result.updateBannedRights {
                if let value = initialUserBannedRights[id] {
                    undoRights[id] = value
                }
            }
        }
        
        do {
            let _ = self.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
            
            for authorId in result.deleteAllFromPeers {
                let _ = self.context.engine.messages.deleteAllMessagesWithAuthor(peerId: peerId, authorId: authorId, namespace: Namespaces.Message.Cloud).startStandalone()
                let _ = self.context.engine.messages.clearAuthorHistory(peerId: peerId, memberId: authorId).startStandalone()
            }
            
            for authorId in result.reportSpamPeers {
                let _ = self.context.engine.peers.reportPeer(peerId: authorId, reason: .spam, message: "").startStandalone()
            }
            
            for authorId in result.banPeers {
                let _ = self.context.engine.peers.removePeerMember(peerId: peerId, memberId: authorId).startStandalone()
            }
            
            for (authorId, rights) in result.updateBannedRights {
                let _ = self.context.engine.peers.updateChannelMemberBannedRights(peerId: peerId, memberId: authorId, rights: rights).startStandalone()
            }
        }
        
        if text.isEmpty {
            text = messageIds.count == 1 ? self.presentationData.strings.Chat_AdminAction_ToastMessagesDeletedTextSingle : self.presentationData.strings.Chat_AdminAction_ToastMessagesDeletedTextMultiple
            if !result.deleteAllFromPeers.isEmpty {
                text = self.presentationData.strings.Chat_AdminAction_ToastMessagesDeletedTextMultiple
            }
            title = nil
        }
        
        self.present(
            UndoOverlayController(
                presentationData: self.presentationData,
                content: undoRights.isEmpty ? .actionSucceeded(title: title, text: text, cancel: nil, destructive: false) : .removedChat(title: title ?? text, text: title == nil ? nil : text),
                elevatedLayout: false,
                action: { [weak self] action in
                    guard let self else {
                        return true
                    }
                    
                    switch action {
                    case .commit:
                        break
                    case .undo:
                        for (authorId, rights) in initialUserBannedRights {
                            let _ = self.context.engine.peers.updateChannelMemberBannedRights(peerId: peerId, memberId: authorId, rights: rights.value).startStandalone()
                        }
                    default:
                        break
                    }
                    return true
                }
            ),
            in: .current
        )
        
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
    }
    
    func presentMultiBanMessageOptions(accountPeerId: PeerId, authors: [Peer], messageIds: Set<MessageId>, options: ChatAvailableMessageActionOptions) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        
        var signal = combineLatest(authors.map { author in
            self.context.engine.peers.fetchChannelParticipant(peerId: peerId, participantId: author.id)
            |> map { result -> (Peer, ChannelParticipant?) in
                return (author, result)
            }
        })
        let disposables = MetaDisposable()
        self.navigationActionDisposable.set(disposables)
        
        var cancelImpl: (() -> Void)?
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let progressSignal = Signal<Never, NoError> { [weak self] subscriber in
            let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
                cancelImpl?()
            }))
            self?.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
            return ActionDisposable { [weak controller] in
                Queue.mainQueue().async() {
                    controller?.dismiss()
                }
            }
        }
        |> runOn(Queue.mainQueue())
        |> delay(0.3, queue: Queue.mainQueue())
        let progressDisposable = progressSignal.startStrict()
        
        signal = signal
        |> afterDisposed {
            Queue.mainQueue().async {
                progressDisposable.dispose()
            }
        }
        cancelImpl = {
            disposables.set(nil)
        }
        
        disposables.set((signal
        |> deliverOnMainQueue).startStrict(next: { [weak self] authorsAndParticipants in
            guard let self else {
                return
            }
            let _ = (self.context.engine.data.get(
                TelegramEngine.EngineData.Item.Peer.Peer(id: peerId)
            )
            |> deliverOnMainQueue).startStandalone(next: { [weak self] chatPeer in
                guard let self, let chatPeer else {
                    return
                }
                var renderedParticipants: [RenderedChannelParticipant] = []
                var initialUserBannedRights: [EnginePeer.Id: InitialBannedRights] = [:]
                for (author, maybeParticipant) in authorsAndParticipants {
                    let participant: ChannelParticipant
                    if let maybeParticipant {
                        participant = maybeParticipant
                    } else {
                        participant = .member(id: author.id, invitedAt: 0, adminInfo: nil, banInfo: ChannelParticipantBannedInfo(
                            rights: TelegramChatBannedRights(
                                flags: [.banReadMessages],
                                untilDate: Int32.max
                            ),
                            restrictedBy: self.context.account.peerId,
                            timestamp: 0,
                            isMember: false
                        ), rank: nil)
                    }
                    
                    let peer = author
                    renderedParticipants.append(RenderedChannelParticipant(
                        participant: participant,
                        peer: peer
                    ))
                    switch participant {
                    case .creator:
                        break
                    case let .member(_, _, _, banInfo, _):
                        if let banInfo {
                            initialUserBannedRights[participant.peerId] = InitialBannedRights(value: banInfo.rights)
                        } else {
                            initialUserBannedRights[participant.peerId] = InitialBannedRights(value: nil)
                        }
                    }
                }
                self.push(AdminUserActionsSheet(
                    context: self.context,
                    chatPeer: chatPeer,
                    peers: renderedParticipants,
                    messageCount: messageIds.count,
                    completion: { [weak self] result in
                        guard let self else {
                            return
                        }
                        self.applyAdminUserActionsResult(messageIds: messageIds, result: result, initialUserBannedRights: initialUserBannedRights)
                    }
                ))
            })
        }))
    }
    
    func presentBanMessageOptions(accountPeerId: PeerId, author: Peer, messageIds: Set<MessageId>, options: ChatAvailableMessageActionOptions) {
        guard let peerId = self.chatLocation.peerId else {
            return
        }
        
        var signal = self.context.engine.peers.fetchChannelParticipant(peerId: peerId, participantId: author.id)
        let disposables = MetaDisposable()
        self.navigationActionDisposable.set(disposables)
        
        var cancelImpl: (() -> Void)?
        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
        let progressSignal = Signal<Never, NoError> { [weak self] subscriber in
            let controller = OverlayStatusController(theme: presentationData.theme, type: .loading(cancelled: {
                cancelImpl?()
            }))
            self?.present(controller, in: .window(.root), with: ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
            return ActionDisposable { [weak controller] in
                Queue.mainQueue().async() {
                    controller?.dismiss()
                }
            }
        }
        |> runOn(Queue.mainQueue())
        |> delay(0.3, queue: Queue.mainQueue())
        let progressDisposable = progressSignal.startStrict()
        
        signal = signal
        |> afterDisposed {
            Queue.mainQueue().async {
                progressDisposable.dispose()
            }
        }
        cancelImpl = {
            disposables.set(nil)
        }
        
        disposables.set((signal
        |> deliverOnMainQueue).startStrict(next: { [weak self] maybeParticipant in
            guard let self else {
                return
            }
            
            let participant: ChannelParticipant
            if let maybeParticipant {
                participant = maybeParticipant
            } else {
                participant = .member(id: author.id, invitedAt: 0, adminInfo: nil, banInfo: ChannelParticipantBannedInfo(
                    rights: TelegramChatBannedRights(
                        flags: [.banReadMessages],
                        untilDate: Int32.max
                    ),
                    restrictedBy: self.context.account.peerId,
                    timestamp: 0,
                    isMember: false
                ), rank: nil)
            }
            
            let _ = (self.context.engine.data.get(
                TelegramEngine.EngineData.Item.Peer.Peer(id: peerId),
                TelegramEngine.EngineData.Item.Peer.Peer(id: author.id)
            )
            |> deliverOnMainQueue).startStandalone(next: { [weak self] chatPeer, authorPeer in
                guard let self, let chatPeer else {
                    return
                }
                guard let authorPeer else {
                    return
                }
                var initialUserBannedRights: [EnginePeer.Id: InitialBannedRights] = [:]
                switch participant {
                case .creator:
                    break
                case let .member(_, _, _, banInfo, _):
                    if let banInfo {
                        initialUserBannedRights[participant.peerId] = InitialBannedRights(value: banInfo.rights)
                    } else {
                        initialUserBannedRights[participant.peerId] = InitialBannedRights(value: nil)
                    }
                }
                self.push(AdminUserActionsSheet(
                    context: self.context,
                    chatPeer: chatPeer,
                    peers: [RenderedChannelParticipant(
                        participant: participant,
                        peer: authorPeer._asPeer()
                    )],
                    messageCount: messageIds.count,
                    completion: { [weak self] result in
                        guard let self else {
                            return
                        }
                        self.applyAdminUserActionsResult(messageIds: messageIds, result: result, initialUserBannedRights: initialUserBannedRights)
                    }
                ))
            })
        }))
        
        /*do {
            self.navigationActionDisposable.set((self.context.engine.peers.fetchChannelParticipant(peerId: peerId, participantId: author.id)
            |> deliverOnMainQueue).startStrict(next: {
                if let strongSelf = self {
                    if "".isEmpty {
                        
                        return
                    }
                    
                    let canBan = participant?.canBeBannedBy(peerId: accountPeerId) ?? true
                    
                    let actionSheet = ActionSheetController(presentationData: strongSelf.presentationData)
                    var items: [ActionSheetItem] = []
                    
                    var actions = Set<Int>([0])
                    
                    let toggleCheck: (Int, Int) -> Void = { [weak actionSheet] category, itemIndex in
                        if actions.contains(category) {
                            actions.remove(category)
                        } else {
                            actions.insert(category)
                        }
                        actionSheet?.updateItem(groupIndex: 0, itemIndex: itemIndex, { item in
                            if let item = item as? ActionSheetCheckboxItem {
                                return ActionSheetCheckboxItem(title: item.title, label: item.label, value: !item.value, action: item.action)
                            }
                            return item
                        })
                    }
                    
                    var itemIndex = 0
                    var categories: [Int] = [0]
                    if canBan {
                        categories.append(1)
                    }
                    categories.append(contentsOf: [2, 3])
                    
                    for categoryId in categories as [Int] {
                        var title = ""
                        if categoryId == 0 {
                            title = strongSelf.presentationData.strings.Conversation_Moderate_Delete
                        } else if categoryId == 1 {
                            title = strongSelf.presentationData.strings.Conversation_Moderate_Ban
                        } else if categoryId == 2 {
                            title = strongSelf.presentationData.strings.Conversation_Moderate_Report
                        } else if categoryId == 3 {
                            title = strongSelf.presentationData.strings.Conversation_Moderate_DeleteAllMessages(EnginePeer(author).displayTitle(strings: strongSelf.presentationData.strings, displayOrder: strongSelf.presentationData.nameDisplayOrder)).string
                        }
                        let index = itemIndex
                        items.append(ActionSheetCheckboxItem(title: title, label: "", value: actions.contains(categoryId), action: { value in
                            toggleCheck(categoryId, index)
                        }))
                        itemIndex += 1
                    }
                    
                    items.append(ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Done, action: { [weak self, weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        if let strongSelf = self {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                            if actions.contains(3) {
                                let _ = strongSelf.context.engine.messages.deleteAllMessagesWithAuthor(peerId: peerId, authorId: author.id, namespace: Namespaces.Message.Cloud).startStandalone()
                                let _ = strongSelf.context.engine.messages.clearAuthorHistory(peerId: peerId, memberId: author.id).startStandalone()
                            } else if actions.contains(0) {
                                let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                            }
                            if actions.contains(1) {
                                let _ = strongSelf.context.engine.peers.removePeerMember(peerId: peerId, memberId: author.id).startStandalone()
                            }
                        }
                    }))
                    
                    actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: strongSelf.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])])
                    strongSelf.chatDisplayNode.dismissInput()
                    strongSelf.present(actionSheet, in: .window(.root))
                }
            }))
        }*/
    }
    
    func presentDeleteMessageOptions(messageIds: Set<MessageId>, options: ChatAvailableMessageActionOptions, contextController: ContextControllerProtocol?, completion: @escaping (ContextMenuActionResult) -> Void) {
        let _ = (self.context.engine.data.get(
            EngineDataMap(messageIds.map(TelegramEngine.EngineData.Item.Messages.Message.init(id:)))
        )
        |> deliverOnMainQueue).start(next: { [weak self] messages in
            guard let self else {
                return
            }
            
            let actionSheet = ActionSheetController(presentationData: self.presentationData)
            var items: [ActionSheetItem] = []
            var personalPeerName: String?
            var isChannel = false
            if let user = self.presentationInterfaceState.renderedPeer?.peer as? TelegramUser {
                personalPeerName = EnginePeer(user).compactDisplayTitle
            } else if let peer = self.presentationInterfaceState.renderedPeer?.peer as? TelegramSecretChat, let associatedPeerId = peer.associatedPeerId, let user = self.presentationInterfaceState.renderedPeer?.peers[associatedPeerId] as? TelegramUser {
                personalPeerName = EnginePeer(user).compactDisplayTitle
            } else if let channel = self.presentationInterfaceState.renderedPeer?.peer as? TelegramChannel, case .broadcast = channel.info {
                isChannel = true
            }
            
            if options.contains(.cancelSending) {
                items.append(ActionSheetButtonItem(title: self.presentationData.strings.Conversation_ContextMenuCancelSending, color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    if let strongSelf = self {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                        let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                    }
                }))
            }
            
            var contextItems: [ContextMenuItem] = []
            var canDisplayContextMenu = true
            
            var unsendPersonalMessages = false
            if options.contains(.unsendPersonal) {
                canDisplayContextMenu = false
                items.append(ActionSheetTextItem(title: self.presentationData.strings.Chat_UnsendMyMessagesAlertTitle(personalPeerName ?? "").string))
                items.append(ActionSheetSwitchItem(title: self.presentationData.strings.Chat_UnsendMyMessages, isOn: false, action: { value in
                    unsendPersonalMessages = value
                }))
            } else if options.contains(.deleteGlobally) {
                let globalTitle: String
                if isChannel {
                    globalTitle = self.presentationData.strings.Conversation_DeleteMessagesForEveryone
                } else if let personalPeerName = personalPeerName {
                    globalTitle = self.presentationData.strings.Conversation_DeleteMessagesFor(personalPeerName).string
                } else {
                    globalTitle = self.presentationData.strings.Conversation_DeleteMessagesForEveryone
                }
                contextItems.append(.action(ContextMenuActionItem(text: globalTitle, textColor: .destructive, icon: { _ in nil }, action: { [weak self] c, f in
                    if let strongSelf = self {
                        var giveaway: TelegramMediaGiveaway?
                        for messageId in messageIds {
                            if let message = strongSelf.chatDisplayNode.historyNode.messageInCurrentHistoryView(messageId) {
                                if let media = message.media.first(where: { $0 is TelegramMediaGiveaway }) as? TelegramMediaGiveaway {
                                    giveaway = media
                                    break
                                }
                            }
                        }
                        let commit = {
                            strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                            let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                        }
                        if let giveaway {
                            let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                            if currentTime < giveaway.untilDate {
                                Queue.mainQueue().after(0.2) {
                                    let dateString = stringForDate(timestamp: giveaway.untilDate, timeZone: .current, strings: strongSelf.presentationData.strings)
                                    strongSelf.present(textAlertController(context: strongSelf.context, updatedPresentationData: strongSelf.updatedPresentationData, title: strongSelf.presentationData.strings.Chat_Giveaway_DeleteConfirmation_Title, text: strongSelf.presentationData.strings.Chat_Giveaway_DeleteConfirmation_Text(dateString).string, actions: [TextAlertAction(type: .destructiveAction, title: strongSelf.presentationData.strings.Common_Delete, action: {
                                        commit()
                                    }), TextAlertAction(type: .defaultAction, title: strongSelf.presentationData.strings.Common_Cancel, action: {
                                    })], parseMarkdown: true), in: .window(.root))
                                }
                                f(.default)
                            } else {
                                f(.dismissWithoutContent)
                                commit()
                            }
                        } else {
                            if "".isEmpty {
                                f(.dismissWithoutContent)
                                commit()
                            } else {
                                c?.dismiss(completion: {
                                    DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1, execute: {
                                        commit()
                                    })
                                })
                            }
                        }
                    }
                })))
                items.append(ActionSheetButtonItem(title: globalTitle, color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    if let strongSelf = self {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                        let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: .forEveryone).startStandalone()
                    }
                }))
            }
            if options.contains(.deleteLocally) {
                var localOptionText = self.presentationData.strings.Conversation_DeleteMessagesForMe
                if self.chatLocation.peerId == self.context.account.peerId {
                    if case .peer(self.context.account.peerId) = self.chatLocation, messages.values.allSatisfy({ message in message?._asMessage().effectivelyIncoming(self.context.account.peerId) ?? false }) {
                        localOptionText = self.presentationData.strings.Chat_ConfirmationRemoveFromSavedMessages
                    } else {
                        localOptionText = self.presentationData.strings.Chat_ConfirmationDeleteFromSavedMessages
                    }
                } else if case .scheduledMessages = self.presentationInterfaceState.subject {
                    localOptionText = messageIds.count > 1 ? self.presentationData.strings.ScheduledMessages_DeleteMany : self.presentationData.strings.ScheduledMessages_Delete
                } else {
                    if options.contains(.unsendPersonal) {
                        localOptionText = self.presentationData.strings.Chat_DeleteMessagesConfirmation(Int32(messageIds.count))
                    } else if case .peer(self.context.account.peerId) = self.chatLocation {
                        if messageIds.count == 1 {
                            localOptionText = self.presentationData.strings.Conversation_Moderate_Delete
                        } else {
                            localOptionText = self.presentationData.strings.Conversation_DeleteManyMessages
                        }
                    }
                }
                contextItems.append(.action(ContextMenuActionItem(text: localOptionText, textColor: .destructive, icon: { _ in nil }, action: { [weak self] c, f in
                    if let strongSelf = self {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                        
                        let commit: () -> Void = {
                            guard let strongSelf = self else {
                                return
                            }
                            let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: unsendPersonalMessages ? .forEveryone : .forLocalPeer).startStandalone()
                        }
                        
                        if "".isEmpty {
                            f(.dismissWithoutContent)
                            commit()
                        } else {
                            c?.dismiss(completion: {
                                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.1, execute: {
                                    commit()
                                })
                            })
                        }
                    }
                })))
                items.append(ActionSheetButtonItem(title: localOptionText, color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    if let strongSelf = self {
                        strongSelf.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState { $0.withoutSelectionState() } })
                        let _ = strongSelf.context.engine.messages.deleteMessagesInteractively(messageIds: Array(messageIds), type: unsendPersonalMessages ? .forEveryone : .forLocalPeer).startStandalone()
                        
                    }
                }))
            }
            
            if canDisplayContextMenu, let contextController = contextController {
                contextController.setItems(.single(ContextController.Items(content: .list(contextItems))), minHeight: nil, animated: true)
            } else {
                actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                    ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                    })
                ])])
                
                if let contextController = contextController {
                    contextController.dismiss(completion: { [weak self] in
                        self?.present(actionSheet, in: .window(.root))
                    })
                } else {
                    self.chatDisplayNode.dismissInput()
                    self.present(actionSheet, in: .window(.root))
                    completion(.default)
                }
            }
        })
    }
    
    func presentClearCacheSuggestion() {
        guard let peer = self.presentationInterfaceState.renderedPeer?.peer else {
            return
        }
        self.updateChatPresentationInterfaceState(animated: true, interactive: true, { $0.updatedInterfaceState({ $0.withoutSelectionState() }) })
        
        let actionSheet = ActionSheetController(presentationData: self.presentationData)
        var items: [ActionSheetItem] = []
        
        items.append(DeleteChatPeerActionSheetItem(context: self.context, peer: EnginePeer(peer), chatPeer: EnginePeer(peer), action: .clearCacheSuggestion, strings: self.presentationData.strings, nameDisplayOrder: self.presentationData.nameDisplayOrder))
        
        var presented = false
        items.append(ActionSheetButtonItem(title: self.presentationData.strings.ClearCache_FreeSpace, color: .accent, action: { [weak self, weak actionSheet] in
           actionSheet?.dismissAnimated()
            if let strongSelf = self, !presented {
                presented = true
                let context = strongSelf.context
                strongSelf.push(StorageUsageScreen(context: context, makeStorageUsageExceptionsScreen: { category in
                    return storageUsageExceptionsScreen(context: context, category: category)
                }))
           }
        }))
    
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
            ActionSheetButtonItem(title: self.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
            })
        ])])
        self.chatDisplayNode.dismissInput()
        self.presentInGlobalOverlay(actionSheet)
    }
}
