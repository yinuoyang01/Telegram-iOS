import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ItemListUI
import PresentationDataUtils
import AccountContext
import UndoUI

enum ItemType: CaseIterable {
    case autoplayVideo
    case autoplayGif
    case loopStickers
    case loopEmoji
    case fullTranslucency
    case autodownloadInBackground
    case extendBackgroundWork
    
    var settingsKeyPath: WritableKeyPath<EnergyUsageSettings, Bool> {
        switch self {
        case .autoplayVideo:
            return \.autoplayVideo
        case .autoplayGif:
            return \.autoplayGif
        case .loopStickers:
            return \.loopStickers
        case .loopEmoji:
            return \.loopEmoji
        case .fullTranslucency:
            return \.fullTranslucency
        case .extendBackgroundWork:
            return \.extendBackgroundWork
        case .autodownloadInBackground:
            return \.autodownloadInBackground
        }
    }
    
    func title(strings: PresentationStrings) -> (String, String, String) {
        //TODO:localize
        switch self {
        case .autoplayVideo:
            return (
                "Settings/Power/PowerIconVideo",
                "Autoplay Videos",
                "Autoplay and loop videos and video messages in chats."
            )
        case .autoplayGif:
            return (
                "Settings/Power/PowerIconGif",
                "Autoplay GIFs",
                "Autoplay and loop GIFs in chats and in the keyboard."
            )
        case .loopStickers:
            return (
                "Settings/Power/PowerIconStickers",
                "Sticker Animations",
                "Loop animated stickers, play full-screen premium effects."
            )
        case .loopEmoji:
            return (
                "Settings/Power/PowerIconEmoji",
                "Emoji Animations",
                "Loop animated emoji in messages, reactions, statuses."
            )
        case .fullTranslucency:
            return (
                "Settings/Power/PowerIconEffects",
                "Interface Effects",
                "Various effects and animations that make Telegram look amazing."
            )
        case .extendBackgroundWork:
            return (
                "Settings/Power/PowerIconBackgroundTime",
                "Extended Background Time",
                "Update chats faster when switching between apps."
            )
        case .autodownloadInBackground:
            return (
                "Settings/Power/PowerIconMedia",
                "Preload Media",
                "Start loading media while in the chat list for faster access."
            )
        }
    }
}

private final class EnergeSavingSettingsScreenArguments {
    let updateThreshold: (Int32) -> Void
    let toggleItem: (ItemType) -> Void
    let displayDisabledTooltip: () -> Void
    
    init(updateThreshold: @escaping (Int32) -> Void, toggleItem: @escaping (ItemType) -> Void, displayDisabledTooltip: @escaping () -> Void) {
        self.updateThreshold = updateThreshold
        self.toggleItem = toggleItem
        self.displayDisabledTooltip = displayDisabledTooltip
    }
}

private enum EnergeSavingSettingsScreenSection: Int32 {
    case all
    case items
}

private enum EnergeSavingSettingsScreenEntry: ItemListNodeEntry {
    enum StableId: Hashable {
        case allHeader
        case all
        case allFooter
        case itemsHeader
        case item(ItemType)
    }
    
    case allHeader(Bool?)
    case all(Int32)
    case allFooter(String)
    case item(index: Int, type: ItemType, value: Bool, enabled: Bool)
    case itemsHeader
    
    var section: ItemListSectionId {
        switch self {
        case .allHeader, .all, .allFooter:
            return EnergeSavingSettingsScreenSection.all.rawValue
        case .item, .itemsHeader:
            return EnergeSavingSettingsScreenSection.items.rawValue
        }
    }
    
    var sortIndex: Int {
        switch self {
        case .allHeader:
            return -4
        case .all:
            return -3
        case .allFooter:
            return -2
        case .itemsHeader:
            return -1
        case let .item(index, _, _, _):
            return index
        }
    }
    
    var stableId: StableId {
        switch self {
        case .allHeader:
            return .allHeader
        case .all:
            return .all
        case .allFooter:
            return .allFooter
        case .itemsHeader:
            return .itemsHeader
        case let .item(_, type, _, _):
            return .item(type)
        }
    }
    
    static func <(lhs: EnergeSavingSettingsScreenEntry, rhs: EnergeSavingSettingsScreenEntry) -> Bool {
        return lhs.sortIndex < rhs.sortIndex
    }
    
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! EnergeSavingSettingsScreenArguments
        switch self {
        case let .allHeader(value):
            //TODO:localize
            let text: String
            if let value {
                let modeValue = value ? "ON" : "OFF"
                text = "POWER SAVING MODE (\(modeValue))"
            } else {
                text = "POWER SAVING MODE"
            }
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .all(value):
            return EnergyUsageBatteryLevelItem(
                theme: presentationData.theme,
                strings: presentationData.strings,
                value: value,
                sectionId: self.section,
                updated: { value in
                    arguments.updateThreshold(value)
                }
            )
        case let .allFooter(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case .itemsHeader:
            //TODO:localize
            return ItemListSectionHeaderItem(presentationData: presentationData, text: "RESOURCE-INTENSIVE PROCESSES", sectionId: self.section)
        case let .item(_, type, value, enabled):
            let (iconName, title, text) = type.title(strings: presentationData.strings)
            return ItemListSwitchItem(presentationData: presentationData, icon: UIImage(bundleImageName: iconName)?.precomposed(), title: title, text: text, value: value, enableInteractiveChanges: true, enabled: enabled, sectionId: self.section, style: .blocks, updated: { value in
                arguments.toggleItem(type)
            }, activatedWhileDisabled: {
                arguments.displayDisabledTooltip()
            })
        }
    }
}

private func energeSavingSettingsScreenEntries(
    presentationData: PresentationData,
    settings: MediaAutoDownloadSettings
) -> [EnergeSavingSettingsScreenEntry] {
    var entries: [EnergeSavingSettingsScreenEntry] = []
    
    let isOn = automaticEnergyUsageShouldBeOnNow(settings: settings)
    
    let allIsOn: Bool?
    if settings.energyUsageSettings.activationThreshold == 0 || settings.energyUsageSettings.activationThreshold == 100 {
        allIsOn = nil
    } else {
        allIsOn = isOn
    }
    entries.append(.allHeader(allIsOn))
    entries.append(.all(settings.energyUsageSettings.activationThreshold))
    
    let allText: String
    if settings.energyUsageSettings.activationThreshold == 0 {
        allText = "Don’t disable all resource-intensive processes even when the battery is low."
    } else if settings.energyUsageSettings.activationThreshold >= 100 {
        allText = "Always disable all resource-intensive processes, regardless of the battery charge level."
    } else {
        allText = "Automatically disable all resource-intensive processes when your battery is below \(settings.energyUsageSettings.activationThreshold)%."
    }
    entries.append(.allFooter(allText))
    
    let itemsEnabled: Bool
    if settings.energyUsageSettings.activationThreshold == 0 {
        itemsEnabled = true
    } else if settings.energyUsageSettings.activationThreshold == 100 {
        itemsEnabled = false
    } else if isOn {
        itemsEnabled = false
    } else {
        itemsEnabled = true
    }
    
    entries.append(.itemsHeader)
    for type in ItemType.allCases {
        entries.append(.item(index: entries.count, type: type, value: settings.energyUsageSettings[keyPath: type.settingsKeyPath] && itemsEnabled, enabled: itemsEnabled))
    }
    
    return entries
}

public func energySavingSettingsScreen(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController) -> Void)?
    let _ = pushControllerImpl
    
    var displayTooltipImpl: ((UndoOverlayContent) -> Void)?
    
    let arguments = EnergeSavingSettingsScreenArguments(
        updateThreshold: { value in
            let _ = updateMediaDownloadSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.energyUsageSettings.activationThreshold = max(0, min(100, value))
                return settings
            }).start()
        },
        toggleItem: { type in
            let _ = updateMediaDownloadSettingsInteractively(accountManager: context.sharedContext.accountManager, { settings in
                var settings = settings
                settings.energyUsageSettings[keyPath: type.settingsKeyPath] = !settings.energyUsageSettings[keyPath: type.settingsKeyPath]
                return settings
            }).start()
        },
        displayDisabledTooltip: {
            //TODO:localize
            let text: String
            if context.sharedContext.currentAutomaticMediaDownloadSettings.energyUsageSettings.activationThreshold == 100 {
                text = "Turn off Power Saving Mode to change these settings."
            } else {
                text = "Turn off Power Saving Mode or charge your phone to change these settings."
            }
            displayTooltipImpl?(.universal(animation: "lowbattery_30", scale: 1.0, colors: [:], title: nil, text: text, customUndoText: nil))
        }
    )
    
    let signal = combineLatest(
        context.sharedContext.presentationData,
        context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings]))
        |> deliverOnMainQueue
        |> map { presentationData, sharedData -> (ItemListControllerState, (ItemListNodeState, Any)) in
            var automaticMediaDownloadSettings: MediaAutoDownloadSettings
            if let value = sharedData.entries[ApplicationSpecificSharedDataKeys.automaticMediaDownloadSettings]?.get(MediaAutoDownloadSettings.self) {
                automaticMediaDownloadSettings = value
            } else {
                automaticMediaDownloadSettings = MediaAutoDownloadSettings.defaultSettings
            }
            
            //TODO:localize
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text("Energy Saving"),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
                animateChanges: false
            )
            let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: energeSavingSettingsScreenEntries(presentationData: presentationData, settings: automaticMediaDownloadSettings), style: .blocks, emptyStateItem: nil, animateChanges: true)
            
            return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        if let controller = controller {
            (controller.navigationController as? NavigationController)?.pushViewController(c)
        }
    }
    displayTooltipImpl = { [weak controller] c in
        if let controller = controller {
            let presentationData = context.sharedContext.currentPresentationData.with({ $0 })
            controller.present(UndoOverlayController(presentationData: presentationData, content: c, elevatedLayout: false, action: { _ in return false }), in: .current)
        }
    }
    return controller
}
