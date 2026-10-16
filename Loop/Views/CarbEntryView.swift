//
//  CarbEntryView.swift
//  Loop
//
//  Created by Noah Brauner on 7/19/23.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import HealthKit

struct CarbEntryView: View, HorizontalSizeClassOverride {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.dismissAction) private var dismiss

    @ObservedObject var viewModel: CarbEntryViewModel
        
    @State private var expandedRow: Row?
    
    @State private var showHowAbsorptionTimeWorks = false
    @State private var showAddFavoriteFood = false
    
    private let isNewEntry: Bool

    /// Formats the carb amount shown on each favorite food row
    private let carbFormatter: QuantityFormatter

    /// Formats the absorption time shown on each favorite food row, e.g. "3h"
    private static let absorptionTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(viewModel: CarbEntryViewModel) {
        if viewModel.shouldBeginEditingQuantity {
            expandedRow = .amountConsumed
        }
        isNewEntry = viewModel.originalCarbEntry == nil
        self.viewModel = viewModel
        carbFormatter = QuantityFormatter(for: viewModel.preferredCarbUnit)
    }
    
    var body: some View {
        if isNewEntry {
            NavigationView {
                let title = NSLocalizedString("carb-entry-title-add", value: "Add Carb Entry", comment: "The title of the view controller to create a new carb entry")
                content
                    .navigationBarTitle(title, displayMode: .inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            dismissButton
                        }
                    }
                
            }
        }
        else {
            content
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        continueButton
                    }
                }
        }
    }
    
    private var content: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .edgesIgnoringSafeArea(.all)
            
            ScrollView {
                warningsCard

                mainCard
                    .padding(.top, 8)
                
                continueActionButton
                
                if isNewEntry, FeatureFlags.allowExperimentalFeatures {
                    favoriteFoodsCard
                }
                
                let isBolusViewActive = Binding(get: { viewModel.bolusViewModel != nil }, set: { _, _ in viewModel.bolusViewModel = nil })
                NavigationLink(destination: bolusView, isActive: isBolusViewActive) {
                    EmptyView()
                }
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibility(hidden: true)
            }
        }
        .alert(item: $viewModel.alert, content: alert(for:))
        .sheet(isPresented: $showAddFavoriteFood, onDismiss: clearExpandedRow) {
            AddEditFavoriteFoodView(carbsQuantity: $viewModel.carbsQuantity.wrappedValue, foodType: $viewModel.foodType.wrappedValue, absorptionTime: $viewModel.absorptionTime.wrappedValue, onSave: onFavoriteFoodSave(_:))
        }
        .sheet(isPresented: $showHowAbsorptionTimeWorks) {
            HowAbsorptionTimeWorksView()
        }
    }
    
    private var mainCard: some View {
        VStack(spacing: 10) {
            let amountConsumedFocused: Binding<Bool> = Binding(get: { expandedRow == .amountConsumed }, set: { expandedRow = $0 ? .amountConsumed : nil })
            let timeFocused: Binding<Bool> = Binding(get: { expandedRow == .time }, set: { expandedRow = $0 ? .time : nil })
            let foodTypeFocused: Binding<Bool> = Binding(get: { expandedRow == .foodType }, set: { expandedRow = $0 ? .foodType : nil })
            let absorptionTimeFocused: Binding<Bool> = Binding(get: { expandedRow == .absorptionTime }, set: { expandedRow = $0 ? .absorptionTime : nil })
            
            CarbQuantityRow(quantity: $viewModel.carbsQuantity, isFocused: amountConsumedFocused, title: NSLocalizedString("Amount Consumed", comment: "Label for carb quantity entry row on carb entry screen"), preferredCarbUnit: viewModel.preferredCarbUnit)

            CardSectionDivider()
            
            DatePickerRow(date: $viewModel.time, isFocused: timeFocused, minimumDate: viewModel.minimumDate, maximumDate: viewModel.maximumDate)
            
            CardSectionDivider()
            
            FoodTypeRow(foodType: $viewModel.foodType, absorptionTime: $viewModel.absorptionTime, selectedDefaultAbsorptionTimeEmoji: $viewModel.selectedDefaultAbsorptionTimeEmoji, usesCustomFoodType: $viewModel.usesCustomFoodType, absorptionTimeWasEdited: $viewModel.absorptionTimeWasEdited, isFocused: foodTypeFocused, defaultAbsorptionTimes: viewModel.defaultAbsorptionTimes)
            
            CardSectionDivider()
            
            AbsorptionTimePickerRow(absorptionTime: $viewModel.absorptionTime, isFocused: absorptionTimeFocused, validDurationRange: viewModel.absorptionRimesRange, showHowAbsorptionTimeWorks: $showHowAbsorptionTimeWorks)
                .padding(.bottom, 2)
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
        .background(CardBackground())
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private var bolusView: some View {
        if let viewModel = viewModel.bolusViewModel {
            BolusEntryView(viewModel: viewModel)
                .environmentObject(displayGlucosePreference)
                .environment(\.dismissAction, dismiss)
        }
    }
    
    private func clearExpandedRow() {
        self.expandedRow = nil
    }
}

// MARK: - Warnings & Alerts
extension CarbEntryView {
    private var warningsCard: some View {
        ForEach(Array(viewModel.warnings).sorted(by: { $0.priority < $1.priority })) { warning in
            warningView(for: warning)
                .padding(.vertical, 8)
                .padding(.horizontal)
                .background(CardBackground())
                .padding(.horizontal)
                .padding(.top, 8)
        }
    }
    
    private func warningView(for warning: CarbEntryViewModel.Warning) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(triangleColor(for: warning))
            
            Text(warningText(for: warning))
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func triangleColor(for warning: CarbEntryViewModel.Warning) -> Color {
        switch warning {
        case .entryIsMissedMeal:
            return .critical
        case .overrideInProgress:
            return .warning
        }
    }
    
    private func warningText(for warning: CarbEntryViewModel.Warning) -> String {
        switch warning {
        case .entryIsMissedMeal:
            return NSLocalizedString("Loop has detected an missed meal and estimated its size. Edit the carb amount to match the amount of any carbs you may have eaten.", comment: "Warning displayed when user is adding a meal from an missed meal notification")
        case .overrideInProgress:
            return NSLocalizedString("An active override is modifying your carb ratio and insulin sensitivity. If you don't want this to affect your bolus calculation and projected glucose, consider turning off the override.", comment: "Warning to ensure the carb entry is accurate during an override")
        }
    }
    
    private func alert(for alert: CarbEntryViewModel.Alert) -> SwiftUI.Alert {
        switch alert {
        case .maxQuantityExceded:
            let message = String(
                format: NSLocalizedString("The maximum allowed amount is %@ grams.", comment: "Alert body displayed for quantity greater than max (1: maximum quantity in grams)"),
                NumberFormatter.localizedString(from: NSNumber(value: viewModel.maxCarbEntryQuantity.doubleValue(for: viewModel.preferredCarbUnit)), number: .none)
            )
            let okMessage = NSLocalizedString("com.loudnate.LoopKit.errorAlertActionTitle", value: "OK", comment: "The title of the action used to dismiss an error alert")
            return SwiftUI.Alert(
                title: Text("Large Meal Entered", comment: "Title of the warning shown when a large meal was entered"),
                message: Text(message),
                dismissButton: .cancel(Text(okMessage), action: viewModel.clearAlert)
            )
        case .warningQuantityValidation:
            let message = String(
                format: NSLocalizedString("Did you intend to enter %1$@ grams as the amount of carbohydrates for this meal?", comment: "Alert body when entered carbohydrates is greater than threshold (1: entered quantity in grams)"),
                NumberFormatter.localizedString(from: NSNumber(value: viewModel.carbsQuantity ?? 0), number: .none)
            )
            return SwiftUI.Alert(
                title: Text("Large Meal Entered", comment: "Title of the warning shown when a large meal was entered"),
                message: Text(message),
                primaryButton: .default(Text("No, edit amount", comment: "The title of the action used when rejecting the the amount of carbohydrates entered."), action: viewModel.clearAlert),
                secondaryButton: .cancel(Text("Yes", comment: "The title of the action used when confirming entered amount of carbohydrates."), action: viewModel.clearAlertAndContinueToBolus)
            )
        }
    }
}

// MARK: - Favorite Foods Card
extension CarbEntryView {
    private var favoriteFoodsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FAVORITE FOODS", comment: "The section title for Carb entry screen where Favorite Foods can be selected")
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 26)
            
            VStack(spacing: 10) {
                if !viewModel.favoriteFoods.isEmpty {
                    favoriteFoodsList

                    CardSectionDivider()
                }

                Button(action: saveAsFavoriteFood) {
                    Text("Save as favorite food", comment: "Button label for saving current carb entry as a new Favorite Food")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.saveFavoriteFoodButtonDisabled)
            }
            .padding(.vertical, 12)
            .padding(.horizontal)
            .background(CardBackground())
            .padding(.horizontal)
        }
    }

    /// Rows beyond this many scroll within the card instead of growing it
    private static let maxVisibleFavoriteRows = 4
    private static let favoriteRowHeight: CGFloat = 52

    /// Every favorite as a tappable row with a checkmark on the selected one; tapping the
    /// selected row again deselects it (index -1), which clears the entry like "None" did.
    /// Rows can be deleted by swiping (iOS 27, where swipe actions work outside a List)
    /// or from a long-press menu on any version.
    private var favoriteFoodsList: some View {
        let count = viewModel.favoriteFoods.count
        let isScrollable = count > Self.maxVisibleFavoriteRows
        // Show a half row past the limit so it reads as scrollable
        let visibleRows = isScrollable ? CGFloat(Self.maxVisibleFavoriteRows) + 0.5 : CGFloat(count)

        // Always a scroll container (disabled when everything fits) so swipe actions have a host
        return ScrollView(.vertical, showsIndicators: isScrollable) {
            VStack(spacing: 0) {
                ForEach(Array(viewModel.favoriteFoods.enumerated()), id: \.element.id) { index, food in
                    favoriteFoodRow(food, isSelected: viewModel.selectedFavoriteFoodIndex == index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.selectedFavoriteFoodIndex = viewModel.selectedFavoriteFoodIndex == index ? -1 : index
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            deleteFavoriteButton(food)
                        }
                        .contextMenu {
                            deleteFavoriteButton(food)
                        }

                    if index < count - 1 {
                        Divider()
                    }
                }
            }
        }
        .scrollDisabledIfAvailable(!isScrollable)
        .frame(height: Self.favoriteRowHeight * visibleRows)
        .favoriteSwipeActionsContainer()
    }

    private func deleteFavoriteButton(_ food: StoredFavoriteFood) -> some View {
        Button(role: .destructive) {
            withAnimation {
                viewModel.deleteFavoriteFood(food)
            }
        } label: {
            Label(String(localized: "Delete", comment: "Button label to delete a favorite food from the carb entry list"), systemImage: "trash")
        }
    }

    private func favoriteFoodRow(_ food: StoredFavoriteFood, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(food.title)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("\(food.carbsString(formatter: carbFormatter)) carbs, \(food.absorptionTimeString(formatter: Self.absorptionTimeFormatter)) absorption", comment: "Favorite food row detail on the carb entry screen (1: carb amount)(2: absorption time)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundColor(.accentColor)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(!isSelected)
        }
        .frame(height: Self.favoriteRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
    
    private func saveAsFavoriteFood() {
        self.showAddFavoriteFood = true
    }
    
    private func onFavoriteFoodSave(_ food: NewFavoriteFood) {
        clearExpandedRow()
        self.showAddFavoriteFood = false
        viewModel.onFavoriteFoodSave(food)
    }
}

// MARK: - Other UI Elements
extension CarbEntryView {
    private var dismissButton: some View {
        Button(action: dismiss) {
            Text("Cancel", comment: "Button label for cancel")
        }
    }
    
    private var continueButton: some View {
        Button(action: viewModel.continueToBolus) {
            Text("Continue", comment: "Button label for continue")
        }
        .disabled(viewModel.continueButtonDisabled)
    }
    
    private var continueActionButton: some View {
        Button(action: viewModel.continueToBolus) {
            Text("Continue", comment: "Button label for continue")
        }
        .buttonStyle(ActionButtonStyle())
        .padding()
        .disabled(viewModel.continueButtonDisabled)
    }
    
}

extension CarbEntryView {
    enum Row {
        case amountConsumed, time, foodType, absorptionTime
    }
}

private extension View {
    /// Lets `swipeActions` work on rows inside a plain ScrollView. The container modifier
    /// is iOS 27+; earlier systems fall back to the rows' long-press menu.
    @ViewBuilder
    func favoriteSwipeActionsContainer() -> some View {
        if #available(iOS 27, *) {
            self.swipeActionsContainer()
        } else {
            self
        }
    }

    /// `scrollDisabled` is iOS 16+; below that the list simply bounces when it already fits
    @ViewBuilder
    func scrollDisabledIfAvailable(_ disabled: Bool) -> some View {
        if #available(iOS 16, *) {
            self.scrollDisabled(disabled)
        } else {
            self
        }
    }
}
