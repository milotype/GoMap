//
//  QuestBuilderController.swift
//  Go Map!!
//
//  Created by Bryce Cogswell on 2/8/23.
//  Copyright © 2023 Bryce Cogswell. All rights reserved.
//

import UIKit

class QuestBuilderFeatureCell: UICollectionViewCell {
	@IBOutlet var label: UILabel?
	@IBAction func deleteItem(_ sender: Any?) {
		onDelete?(self)
	}

	var onDelete: ((QuestBuilderFeatureCell) -> Void)?

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		contentView.layer.cornerRadius = 5
		contentView.layer.masksToBounds = true
	}
}

class QuestBuilderController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
	UITextFieldDelegate
{
	typealias PresetsForKey = [String: ContiguousArray<PresetFeature>]

	@IBOutlet var presetField: UIButton?
	@IBOutlet var includeFeaturesView: UICollectionView?
	@IBOutlet var excludeFeaturesView: UICollectionView?
	@IBOutlet var includeFeaturesHeightConstraint: NSLayoutConstraint?
	@IBOutlet var excludeFeaturesHeightConstraint: NSLayoutConstraint?
	@IBOutlet var scrollView: UIScrollView?
	@IBOutlet var saveButton: UIBarButtonItem?
	@IBOutlet var nameField: UITextField? // Long name, like "Add Surface"
	@IBOutlet var labelField: UITextField? // Short name for a quest button, like "S"
	@IBOutlet var addOneIncludeButton: UIButton?
	@IBOutlet var addOneExcludeButton: UIButton?
	var quest: QuestUserDefition?

	var featuresForKey: PresetsForKey = [:]
	var moreFeaturesForKey: PresetsForKey = [:]

	var allFeatures: [PresetFeature] = [] // all features for current presetField
	var includeFeatures: [(name: String, ident: String)] = []
	var excludeFeatures: [(name: String, ident: String)] = []

	@available (iOS 15, *)
	public class func instantiateNew() -> UINavigationController {
		let sb = UIStoryboard(name: "QuestBuilder", bundle: nil)
		let vc = sb.instantiateViewController(withIdentifier: "QuestBuilderNavigation") as! UINavigationController
		return vc
	}

	@available (iOS 15, *)
	public class func instantiateWith(quest: QuestUserDefition) -> UIViewController {
		let sb = UIStoryboard(name: "QuestBuilder", bundle: nil)
		let vc = sb.instantiateViewController(withIdentifier: "QuestBuilder") as! QuestBuilderController
		vc.quest = quest
		return vc
	}

	@IBAction func onSave(_ sender: Any?) {
		do {
			let name = nameField!.text!.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
			let label = labelField!.text!.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
			let quest = QuestUserDefition(title: name,
			                              label: label,
			                              presetKey: presetField!.title(for: .normal)!,
			                              includeFeatures: includeFeatures.map { $0.ident },
			                              excludeFeatures: excludeFeatures.map { $0.ident })
			try QuestList.shared.addQuest(quest)
			onCancel(sender)
		} catch {
			let alertView = UIAlertController(title: NSLocalizedString("Quest Definition Error", comment: ""),
			                                  message: error.localizedDescription,
			                                  preferredStyle: .actionSheet)
			alertView.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""),
			                                  style: .cancel))
			present(alertView, animated: true)
			return
		}
	}

	@IBAction func onCancel(_ sender: Any?) {
		if navigationController?.popViewController(animated: true) == nil {
			dismiss(animated: true)
		}
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		for featureView in [includeFeaturesView, excludeFeaturesView] {
			featureView?.layer.borderWidth = 1.0
			featureView?.layer.borderColor = UIColor.gray.cgColor
			featureView?.layer.cornerRadius = 5.0
		}

		// monitor changes to nameField
		nameField?.delegate = self
		nameField?.addTarget(self, action: #selector(nameFieldDidChange(_:)), for: .editingChanged)
		labelField?.delegate = self
		labelField?.addTarget(self, action: #selector(labelFieldDidChange(_:)), for: .editingChanged)
		saveButton?.isEnabled = false

		// monitor when keyboard is visible
		registerKeyboardNotifications()

		if #available(iOS 13.0, *) {
			// prevent swiping down to dismiss
			self.isModalInPresentation = true
		}

		if let flowLayout = includeFeaturesView?.collectionViewLayout as? UICollectionViewFlowLayout {
			flowLayout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize
		}

		if #available(iOS 14.0, *) {
			// get all possible keys
			(featuresForKey, moreFeaturesForKey) = buildFeaturesForKey()
			let keys = Array(featuresForKey.keys) + Array(moreFeaturesForKey.keys)
			let handler: (_: Any?) -> Void = { [weak self] _ in self?.presetKeyChanged() }
			let presetItems: [UIAction] = keys.sorted()
				.map { UIAction(title: "\($0)", handler: handler) }
			presetField?.menu = UIMenu(title: NSLocalizedString("Tag Key", comment: ""),
			                           children: presetItems)
			presetField?.showsMenuAsPrimaryAction = true
		}

		// if we're editing an existing quest then fill in the fields
		if let quest = quest {
			let features = PresetsDatabase.shared.stdFeatures
			includeFeatures = quest.includeFeatures.map { (features[$0]?.name ?? $0, $0) }
			excludeFeatures = quest.excludeFeatures.map { (features[$0]?.name ?? $0, $0) }
			nameField?.text = quest.title
			presetField?.setTitle(quest.presetKey, for: .normal)
			if #available(iOS 14.0, *) {
				// select the current presetKey
				if let item = presetField?.menu?.children.first(where: { $0.title == quest.presetKey }),
				   let action = item as? UIAction
				{
					action.state = .on
				}
			}
			allFeatures = featuresForKey[quest.presetKey]?.sorted(by: { a, b in a.name < b.name }) ?? []
		} else {
			if #available(iOS 15.0, *) {
				let key = presetField?.menu?.selectedElements.first?.title ?? ""
				allFeatures = featuresForKey[key]?.sorted(by: { a, b in a.name < b.name }) ?? []
			}
		}

		setupAddOneMenu(button: addOneIncludeButton!,
						featureList: { [weak self] in self?.includeFeatures ?? [] },
		                featureView: includeFeaturesView!,
						addFeature: { [weak self] in self?.includeFeatures.append($0) })
		setupAddOneMenu(button: addOneExcludeButton!,
		                featureList: { [weak self] in self?.excludeFeatures ?? [] },
		                featureView: excludeFeaturesView!,
						addFeature: { [weak self] in self?.excludeFeatures.append($0) })
	}

	private func setupAddOneMenu(button: UIButton,
	                             featureList: @escaping () -> [(name: String, ident: String)],
	                             featureView: UICollectionView,
	                             addFeature: @escaping ((name: String, ident: String)) -> Void)
	{
		if #available(iOS 15.0, *) {
			let deferred = UIDeferredMenuElement.uncached { [weak self] completion in
				let featureList = featureList()
				let items: [UIAction] = (self?.allFeatures ?? [])
					.map { feature in UIAction(title: "\(feature.name)", handler: { _ in
						let newFeature = (feature.name, feature.featureID)
						if !featureList.contains(where: { $0.ident == newFeature.1 }) {
							addFeature(newFeature)
						}
						featureView.reloadData()
					}) }
				completion(items)
			}
			button.menu = UIMenu(children: [
				UIAction(title: "", handler: { _ in }),
				deferred
			])
			button.showsMenuAsPrimaryAction = true
			button.setTitle("+", for: .normal)
		}
	}

	func presetKeyChanged() {
		let key = presetField!.title(for: .normal)!

		var features = featuresForKey[key] ?? []
		if features.count < 5 {
			features = (featuresForKey[key] ?? []) + (moreFeaturesForKey[key] ?? [])
		}
		allFeatures = features.sorted(by: { a, b in a.name < b.name })
		didAddAllInclude(nil)
		didRemoveAllExclude(nil)
	}

	@IBAction func didAddMoreInclude(_ sender: Any?) {
		let key = presetField!.title(for: .normal)!
		allFeatures = ((featuresForKey[key] ?? []) + (moreFeaturesForKey[key] ?? []))
			.sorted(by: { a, b in a.name < b.name })
		didAddAllInclude(sender)
	}

	@IBAction func didAddAllInclude(_ sender: Any?) {
		includeFeatures = allFeatures.map { ($0.name, $0.featureID) }
		includeFeaturesView?.reloadData()
	}

	@IBAction func didAddAllExclude(_ sender: Any?) {
		excludeFeatures = allFeatures.map { ($0.name, $0.featureID) }
		excludeFeaturesView?.reloadData()
	}

	@IBAction func didRemoveAllInclude(_ sender: Any?) {
		includeFeatures = []
		includeFeaturesView?.reloadData()
	}

	@IBAction func didRemoveAllExclude(_ sender: Any?) {
		excludeFeatures = []
		excludeFeaturesView?.reloadData()
	}

	private func buildFeaturesForKey() -> (PresetsForKey, PresetsForKey) {
		func addFields(to dict: inout PresetsForKey, forFeature feature: PresetFeature, fieldNameList: [String]) {
			for fieldName in fieldNameList {
				guard let field = PresetsDatabase.shared.presetFields[fieldName] else { continue }
				if let key = field.key {
					/*
					 if field.reference?["key"] == key {
					 	continue
					 }
					  */
					if dict[key]?.append(feature) == nil {
						dict[key] = [feature]
					}
				}
				for key in field.keys ?? [] {
					if dict[key]?.append(feature) == nil {
						dict[key] = [feature]
					}
				}
			}
		}

		var dict = PresetsForKey()
		var more = PresetsForKey()
		for feature in PresetsDatabase.shared.stdFeatures.values {
			addFields(to: &dict, forFeature: feature, fieldNameList: feature.fields ?? [])
			addFields(to: &more, forFeature: feature, fieldNameList: feature.moreFields ?? [])
		}
		return (dict, more)
	}

	static func presentVersionAlert(_ vc: UIViewController) {
		let alert = UIAlertController(
			title: NSLocalizedString("Error", comment: ""),
			message: NSLocalizedString("This feature is only available on iOS 15 or later", comment: ""),
			preferredStyle: .alert)
		alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: nil))
		vc.present(alert, animated: true)
	}

	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		let heightInclude = includeFeaturesView?.collectionViewLayout.collectionViewContentSize.height ?? 0.0
		includeFeaturesHeightConstraint?.constant = max(heightInclude, 25.0)

		let heightExclude = excludeFeaturesView?.collectionViewLayout.collectionViewContentSize.height ?? 0.0
		excludeFeaturesHeightConstraint?.constant = max(heightExclude, 25.0)

		view.layoutIfNeeded()
	}

	func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
		guard section == 0 else { return 0 }
		if collectionView === includeFeaturesView {
			return includeFeatures.count
		}
		if collectionView === excludeFeaturesView {
			return excludeFeatures.count
		}
		return 0
	}

	func collectionView(_ collectionView: UICollectionView,
	                    cellForItemAt indexPath: IndexPath) -> UICollectionViewCell
	{
		let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "FeatureCell",
		                                              for: indexPath) as! QuestBuilderFeatureCell
		if collectionView === includeFeaturesView {
			cell.label?.text = includeFeatures[indexPath.row].name
		} else {
			cell.label?.text = excludeFeatures[indexPath.row].name
		}
		cell.onDelete = { [weak self] cell in
			if let self = self,
			   let indexPath = collectionView.indexPath(for: cell)
			{
				if collectionView === self.includeFeaturesView {
					self.includeFeatures.remove(at: indexPath.row)
				} else {
					self.excludeFeatures.remove(at: indexPath.row)
				}
				collectionView.deleteItems(at: [indexPath])
				self.viewDidLayoutSubviews()
			}
		}
		return cell
	}

	@objc func nameFieldDidChange(_ sender: Any?) {
		let text = nameField?.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
		saveButton?.isEnabled = text.count > 0
	}

	@objc func labelFieldDidChange(_ sender: Any?) {
		let text = labelField?.text?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
		saveButton?.isEnabled = text.count == 1
	}

	// MARK: keyboard

	@objc func textFieldShouldReturn(_ textField: UITextField) -> Bool {
		textField.resignFirstResponder()
		return false
	}

	func registerKeyboardNotifications() {
		NotificationCenter.default.addObserver(self,
		                                       selector: #selector(keyboardWillShow(notification:)),
		                                       name: UIResponder.keyboardWillShowNotification,
		                                       object: nil)
		NotificationCenter.default.addObserver(self,
		                                       selector: #selector(keyboardWillHide(notification:)),
		                                       name: UIResponder.keyboardWillHideNotification,
		                                       object: nil)
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		NotificationCenter.default.removeObserver(self)
	}

	@objc func keyboardWillShow(notification: NSNotification) {
		if let userInfo: NSDictionary = notification.userInfo as? NSDictionary,
		   let keyboardInfo = userInfo[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue
		{
			guard let scrollView = scrollView,
			      let nameField = nameField
			else { return }
			let keyboardSize = keyboardInfo.cgRectValue.size
			let contentInsets = UIEdgeInsets(top: 0, left: 0, bottom: keyboardSize.height, right: 0)
			scrollView.contentInset = contentInsets
			scrollView.scrollIndicatorInsets = contentInsets
			let rect = nameField.frame.offsetBy(dx: 0, dy: keyboardSize.height)
			scrollView.scrollRectToVisible(rect, animated: true)
		}
	}

	@objc func keyboardWillHide(notification: NSNotification) {
		scrollView?.contentInset = .zero
		scrollView?.scrollIndicatorInsets = .zero
	}
}
