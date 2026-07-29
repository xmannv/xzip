import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore

extension AppModel {
    // MARK: - Presets (persisted via PresetStore)

    /// Persist the current presets array to disk.
    func savePresets() {
        do {
            try service.presetStore.save(presets.map(ModelMapping.corePreset(from:)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPreset(_ preset: ArchivePreset) {
        presets.append(preset)
        savePresets()
    }

    func updatePreset(_ preset: ArchivePreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        savePresets()
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        savePresets()
    }

    func restoreDefaultPresets() {
        presets = PresetStore.defaultPresets.map(ModelMapping.uiPreset(from:))
        savePresets()
    }
}
