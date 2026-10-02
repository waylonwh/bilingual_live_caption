import CaptionCore
import SwiftUI

struct ControlsView: View {
    @ObservedObject var model: CaptionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    Image(systemName: "waveform.bubble.fill")
                        .font(.system(size: 34)).foregroundStyle(.indigo)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bilingual Live Caption").font(.title2.bold())
                        Text("One audio stream. Two languages.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.isRunning ? "LIVE" : model.isPreview ? "PREVIEW" : "READY")
                        .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 5)
                        .background((model.isRunning ? Color.green : Color.indigo).opacity(0.12), in: Capsule())
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Original captions").font(.headline)
                        Picker("Transcription", selection: Binding(get: { model.mode }, set: { model.changeMode($0) })) {
                            ForEach(TranscriptionMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .disabled(model.isBusy || model.isSwitching || model.isInstalling)
                        Text(model.mode == .apple
                             ? "Original speech is transcribed on this Mac. Audio is also sent to OpenAI for translation."
                             : "Audio is sent to two OpenAI sessions, one for transcription and one for translation.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Text(model.appleStatus).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if !model.appleInstalled {
                                Button("Prepare Apple Model") { model.downloadAppleModel() }
                                    .disabled(!model.canConfigure)
                                    .help("Download Apple's speech model for the selected source language to this Mac.")
                            }
                        }
                        if model.isInstalling { ProgressView(value: model.downloadFraction) }
                    }.padding(6)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                    GridRow {
                        Text("Audio source")
                        HStack {
                            Picker("Audio source", selection: $model.selectedApp) {
                                Text("All computer audio").tag("")
                                if !model.selectedApp.isEmpty && !model.applications.contains(where: { $0.id == model.selectedApp }) {
                                    Text("\(model.selectedApp) — refresh to check").tag(model.selectedApp)
                                }
                                ForEach(model.applications) { app in Text(app.name).tag(app.id) }
                            }.labelsHidden()
                            Button { model.refreshApplications() } label: { Image(systemName: "arrow.clockwise") }
                                .help("Refresh the list of running apps.")
                        }
                    }
                    GridRow {
                        Text("Languages")
                        HStack {
                            Picker("Spoken language", selection: $model.sourceLanguage) {
                                ForEach(CaptionLanguage.sources) { Text($0.name).tag($0.id) }
                            }.labelsHidden()
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Picker("Translation language", selection: $model.targetLanguage) {
                                ForEach(CaptionLanguage.targets) { Text($0.name).tag($0.id) }
                            }.labelsHidden()
                        }
                    }
                    GridRow {
                        Text("Keywords")
                        TextField("Optional terms, separated by commas", text: $model.keywords)
                    }
                    GridRow {
                        Text("OpenAI API key")
                        HStack {
                            SecureField("sk-…", text: $model.apiKey).onSubmit { model.saveAPIKey() }
                            Button("Save") { model.saveAPIKey() }
                        }
                    }
                }
                .textFieldStyle(.roundedBorder).disabled(!model.canConfigure)

                Text("\(model.keychainStatus) Clear the field to remove the saved key. Keywords help transcription only.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.preferencesError {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }

                GroupBox("Caption window") {
                    VStack(spacing: 10) {
                        HStack {
                            Text("Original").frame(width: 80, alignment: .leading)
                            Slider(value: $model.fontSize, in: 12...48, step: 1)
                            Text("\(Int(model.fontSize))").monospacedDigit().frame(width: 24)
                            ColorPicker("Original color", selection: $model.originalColor, supportsOpacity: false).labelsHidden()
                        }
                        HStack {
                            Text("Translation").frame(width: 80, alignment: .leading)
                            Slider(value: $model.translationFontSize, in: 12...48, step: 1)
                            Text("\(Int(model.translationFontSize))").monospacedDigit().frame(width: 24)
                            ColorPicker("Translation color", selection: $model.translationColor, supportsOpacity: false).labelsHidden()
                        }
                        HStack {
                            Text("Background").frame(width: 80, alignment: .leading)
                            Slider(value: $model.opacity, in: 0...1)
                            Text("\(Int(model.opacity * 100))%").monospacedDigit().frame(width: 36)
                            ColorPicker("Background color", selection: $model.backgroundColor, supportsOpacity: false).labelsHidden()
                        }
                        HStack {
                            Button(model.isOverlayVisible ? "Hide Caption Window" : "Show Caption Window") {
                                if model.isOverlayVisible { model.hideOverlay?() }
                                else { model.showOverlay?() }
                            }
                            Button("Preview") { model.preview() }.disabled(!model.canConfigure)
                            Spacer()
                            Button("Clear Text") { model.clearCaptions() }.disabled(model.isBusy)
                        }
                        Text("Drag to move; drag an edge to resize. Click captions, then Esc to hide. Hiding does not stop transcription.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }

                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Circle().fill(model.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                            Text(model.status).font(.callout)
                        }
                        Text(String(format: "Approx. US$%.2f/hour · This run: $%.3f · %02d:%02d", model.mode.ratePerMinute * 60, model.estimatedCost, Int(model.elapsed) / 60, Int(model.elapsed) % 60))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    if model.isRunning || model.isBusy || model.isPreview {
                        Button("Stop") { model.stop() }.buttonStyle(.borderedProminent).tint(.red)
                    } else {
                        Button("Start Captions") { model.start() }.buttonStyle(.borderedProminent)
                            .disabled(model.isInstalling)
                    }
                }
                Text("Start Captions sends the selected audio to OpenAI and incurs API charges. Closing the controls does not stop capture; use Stop or Quit. Cost is an estimate, not an invoice.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(24)
        }
        .task(id: model.sourceLanguage) { await model.checkAppleModel() }
    }
}

struct OverlayView: View {
    @ObservedObject var model: CaptionModel

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = max(0, geometry.size.height - 8)
            let originalHeight = availableHeight * model.fontSize / (model.fontSize + model.translationFontSize)
            VStack(alignment: .leading, spacing: 8) {
                captionLane(text: model.originalCaption, size: model.fontSize, color: model.originalColor)
                    .frame(height: originalHeight)
                captionLane(text: model.translationCaption, size: model.translationFontSize, color: model.translationColor)
                    .frame(height: availableHeight - originalHeight)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(model.backgroundColor.opacity(model.opacity))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func captionLane(text: String, size: Double, color: Color) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: size))
                        .foregroundStyle(color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .scrollIndicators(.never)
            .onChange(of: text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: size) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }.frame(maxHeight: .infinity)
    }
}
