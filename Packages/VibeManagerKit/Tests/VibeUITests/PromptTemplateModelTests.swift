import Foundation
import Testing
import VibeApplication
import VibeDomain

@testable import VibeUI

private let review = PromptTemplate(
  name: "Review", sessionNamePattern: "Review {{url}}", body: "Review {{url}}.\n\n{{focus?}}")
private let feedback = PromptTemplate(
  name: "Feedback", sessionNamePattern: "Feedback {{url}}", body: "Address comments on {{url}}.")

@MainActor
@Suite("The prompt template library")
struct PromptTemplateLibraryModelTests {
  private func makeModel(_ templates: [PromptTemplate] = []) async -> PromptTemplateLibraryModel {
    let model = PromptTemplateLibraryModel(
      repository: InMemoryPromptTemplateRepository(templates: templates))
    await model.load()
    return model
  }

  @Test("A new template is saved once it has a name and a prompt, at revision 1")
  func newTemplateIsSavedExplicitly() async {
    let model = await makeModel()
    model.newTemplate()
    #expect(model.isNew)
    #expect(!model.canSave)
    model.editing?.body = "Review {{url}}"
    #expect(model.canSave)
    #expect(model.all.isEmpty)

    let saved = await model.save()
    #expect(saved)
    #expect(model.all.map(\.revision) == [1])
    #expect(!model.isEdited)
  }

  @Test("A new template left blank has nothing to save or lose")
  func blankNewTemplateIsNotEdited() async {
    let model = await makeModel([review])
    model.newTemplate()
    #expect(model.isNew)
    #expect(!model.isEdited)
    model.requestSelect(review.id)
    #expect(model.pendingNavigation == nil)
    #expect(model.editing?.id == review.id)

    model.newTemplate()
    model.editing?.name = "Mine"
    #expect(model.isEdited)
  }

  @Test("Going to another template with changes asks first")
  func unsavedChangesAsk() async {
    let model = await makeModel([review, feedback])
    model.requestSelect(review.id)
    model.editing?.body = "Changed {{url}}"
    model.requestSelect(feedback.id)
    #expect(model.pendingNavigation == .select(feedback.id))
    #expect(model.selectedID == review.id)

    // The dialog is dismissed before its button runs, which must not lose the answer.
    model.dismissPendingNavigation()
    await model.resolve(.select(feedback.id), saving: false)
    #expect(model.selectedID == feedback.id)
    #expect(model.library.template(id: review.id)?.body == review.body)
  }

  @Test("Save in the question writes the changes, then goes on")
  func saveThenGo() async {
    let model = await makeModel([review, feedback])
    model.requestSelect(review.id)
    model.editing?.body = "Changed {{url}}"
    model.requestSelect(feedback.id)
    model.dismissPendingNavigation()
    await model.resolve(.select(feedback.id), saving: true)
    #expect(model.selectedID == feedback.id)
    #expect(model.library.template(id: review.id)?.body == "Changed {{url}}")
  }

  @Test("A new template waits for the changes to the current one to be dealt with")
  func newTemplateAsksFirst() async {
    let model = await makeModel([review])
    model.requestSelect(review.id)
    model.editing?.body = "Changed {{url}}"
    model.newTemplate()
    #expect(model.pendingNavigation == .newTemplate)
    #expect(model.editing?.body == "Changed {{url}}")
  }

  @Test("Deleting the template on screen removes it and leaves nothing selected")
  func deleteSelected() async {
    let model = await makeModel([review, feedback])
    model.requestSelect(review.id)
    await model.delete(review.id)
    #expect(model.all.map(\.id) == [feedback.id])
    #expect(model.selectedID == nil)
    #expect(model.editing == nil)
  }

  @Test("Add Examples adds them once")
  func examplesOnce() async {
    let model = await makeModel()
    #expect(model.canAddExamples)
    await model.addExamples()
    #expect(model.all.count == 2)
    #expect(!model.canAddExamples)
  }

  @Test("The sheet hears of every saved change")
  func sheetHearsChanges() async {
    let model = await makeModel([review])
    var heard: [PromptTemplateLibrary] = []
    model.libraryDidChange = { heard.append($0) }
    await model.delete(review.id)
    #expect(heard.count == 1)
    #expect(heard.first?.templates.isEmpty == true)
  }
}
