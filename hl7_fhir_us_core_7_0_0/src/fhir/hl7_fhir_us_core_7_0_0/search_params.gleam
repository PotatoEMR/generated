////[https://hl7.org/fhir/hl7_fhir_us_core_7_0_0](https://hl7.org/fhir/hl7_fhir_us_core_7_0_0) hl7_fhir_us_core_7_0_0 search params

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub fn to_string(params) {
  list.fold(
    from: [],
    over: params,
    with: fn(acc, param: #(String, Option(String))) {
      case param.1 {
        None -> acc
        Some(p) -> [param.0 <> "=" <> p, ..acc]
      }
    },
  )
  |> string.join("&")
}

pub type Bundle {
  Bundle(
    identifier: Option(String),
    composition: Option(String),
    type_: Option(String),
    message: Option(String),
    timestamp: Option(String),
  )
}

pub type Endpoint {
  Endpoint(
    payload_type: Option(String),
    identifier: Option(String),
    organization: Option(String),
    connection_type: Option(String),
    name: Option(String),
    status: Option(String),
  )
}

pub type Operationoutcome {
  Operationoutcome
}

pub type HeadOccipitalFrontalCircumferencePercentile {
  HeadOccipitalFrontalCircumferencePercentile(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type PediatricBmiForAge {
  PediatricBmiForAge(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type PediatricWeightForHeight {
  PediatricWeightForHeight(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreAllergyintolerance {
  UsCoreAllergyintolerance(
    clinical_status: Option(String),
    patient: Option(String),
  )
}

pub type UsCoreAverageBloodPressure {
  UsCoreAverageBloodPressure(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreBloodPressure {
  UsCoreBloodPressure(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreBmi {
  UsCoreBmi(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreBodyHeight {
  UsCoreBodyHeight(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreBodyTemperature {
  UsCoreBodyTemperature(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreBodyWeight {
  UsCoreBodyWeight(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreCareExperiencePreference {
  UsCoreCareExperiencePreference(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreCareplan {
  UsCoreCareplan(
    category: Option(String),
    date: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreCareteam {
  UsCoreCareteam(
    patient: Option(String),
    role: Option(String),
    status: Option(String),
  )
}

pub type UsCoreConditionEncounterDiagnosis {
  UsCoreConditionEncounterDiagnosis(
    abatement_date: Option(String),
    asserted_date: Option(String),
    category: Option(String),
    clinical_status: Option(String),
    code: Option(String),
    encounter: Option(String),
    onset_date: Option(String),
    patient: Option(String),
    recorded_date: Option(String),
    lastupdated: Option(String),
  )
}

pub type UsCoreConditionProblemsHealthConcerns {
  UsCoreConditionProblemsHealthConcerns(
    abatement_date: Option(String),
    asserted_date: Option(String),
    category: Option(String),
    clinical_status: Option(String),
    code: Option(String),
    encounter: Option(String),
    onset_date: Option(String),
    patient: Option(String),
    recorded_date: Option(String),
    lastupdated: Option(String),
  )
}

pub type UsCoreCoverage {
  UsCoreCoverage(patient: Option(String))
}

pub type UsCoreDiagnosticreportLab {
  UsCoreDiagnosticreportLab(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreDiagnosticreportNote {
  UsCoreDiagnosticreportNote(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreDocumentreference {
  UsCoreDocumentreference(
    id: Option(String),
    category: Option(String),
    date: Option(String),
    patient: Option(String),
    period: Option(String),
    status: Option(String),
    type_: Option(String),
  )
}

pub type UsCoreEncounter {
  UsCoreEncounter(
    id: Option(String),
    class: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    discharge_disposition: Option(String),
    identifier: Option(String),
    location: Option(String),
    patient: Option(String),
    status: Option(String),
    type_: Option(String),
  )
}

pub type UsCoreGoal {
  UsCoreGoal(
    description: Option(String),
    lifecycle_status: Option(String),
    patient: Option(String),
    target_date: Option(String),
  )
}

pub type UsCoreHeadCircumference {
  UsCoreHeadCircumference(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreHeartRate {
  UsCoreHeartRate(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreImmunization {
  UsCoreImmunization(
    date: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreImplantableDevice {
  UsCoreImplantableDevice(
    patient: Option(String),
    status: Option(String),
    type_: Option(String),
  )
}

pub type UsCoreLocation {
  UsCoreLocation(
    address: Option(String),
    address_city: Option(String),
    address_postalcode: Option(String),
    address_state: Option(String),
    name: Option(String),
  )
}

pub type UsCoreMedication {
  UsCoreMedication
}

pub type UsCoreMedicationdispense {
  UsCoreMedicationdispense(
    patient: Option(String),
    status: Option(String),
    type_: Option(String),
  )
}

pub type UsCoreMedicationrequest {
  UsCoreMedicationrequest(
    authoredon: Option(String),
    encounter: Option(String),
    intent: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreObservationClinicalResult {
  UsCoreObservationClinicalResult(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreObservationLab {
  UsCoreObservationLab(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreObservationOccupation {
  UsCoreObservationOccupation(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreObservationPregnancyintent {
  UsCoreObservationPregnancyintent(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreObservationPregnancystatus {
  UsCoreObservationPregnancystatus(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreObservationScreeningAssessment {
  UsCoreObservationScreeningAssessment(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreObservationSexualOrientation {
  UsCoreObservationSexualOrientation(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreOrganization {
  UsCoreOrganization(address: Option(String), name: Option(String))
}

pub type UsCorePatient {
  UsCorePatient(
    id: Option(String),
    birthdate: Option(String),
    death_date: Option(String),
    family: Option(String),
    gender: Option(String),
    given: Option(String),
    identifier: Option(String),
    name: Option(String),
  )
}

pub type UsCorePractitioner {
  UsCorePractitioner(
    id: Option(String),
    identifier: Option(String),
    name: Option(String),
  )
}

pub type UsCorePractitionerrole {
  UsCorePractitionerrole(
    practitioner: Option(String),
    specialty: Option(String),
  )
}

pub type UsCoreProcedure {
  UsCoreProcedure(
    code: Option(String),
    date: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreProvenance {
  UsCoreProvenance
}

pub type UsCorePulseOximetry {
  UsCorePulseOximetry(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreQuestionnaireresponse {
  UsCoreQuestionnaireresponse(
    id: Option(String),
    authored: Option(String),
    patient: Option(String),
    questionnaire: Option(String),
    status: Option(String),
  )
}

pub type UsCoreRelatedperson {
  UsCoreRelatedperson(
    id: Option(String),
    name: Option(String),
    patient: Option(String),
  )
}

pub type UsCoreRespiratoryRate {
  UsCoreRespiratoryRate(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreServicerequest {
  UsCoreServicerequest(
    id: Option(String),
    authored: Option(String),
    category: Option(String),
    code: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreSimpleObservation {
  UsCoreSimpleObservation(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreSmokingstatus {
  UsCoreSmokingstatus(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreSpecimen {
  UsCoreSpecimen(id: Option(String), patient: Option(String))
}

pub type UsCoreTreatmentInterventionPreference {
  UsCoreTreatmentInterventionPreference(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub type UsCoreVitalSigns {
  UsCoreVitalSigns(
    category: Option(String),
    code: Option(String),
    date: Option(String),
    lastupdated: Option(String),
    patient: Option(String),
    status: Option(String),
  )
}

pub fn bundle_new() {
  Bundle(None, None, None, None, None)
}

pub fn endpoint_new() {
  Endpoint(None, None, None, None, None, None)
}

pub fn operationoutcome_new() {
  Operationoutcome
}

pub fn head_occipital_frontal_circumference_percentile_new() {
  HeadOccipitalFrontalCircumferencePercentile(
    None,
    None,
    None,
    None,
    None,
    None,
  )
}

pub fn pediatric_bmi_for_age_new() {
  PediatricBmiForAge(None, None, None, None, None, None)
}

pub fn pediatric_weight_for_height_new() {
  PediatricWeightForHeight(None, None, None, None, None, None)
}

pub fn us_core_allergyintolerance_new() {
  UsCoreAllergyintolerance(None, None)
}

pub fn us_core_average_blood_pressure_new() {
  UsCoreAverageBloodPressure(None, None, None, None, None, None)
}

pub fn us_core_blood_pressure_new() {
  UsCoreBloodPressure(None, None, None, None, None, None)
}

pub fn us_core_bmi_new() {
  UsCoreBmi(None, None, None, None, None, None)
}

pub fn us_core_body_height_new() {
  UsCoreBodyHeight(None, None, None, None, None, None)
}

pub fn us_core_body_temperature_new() {
  UsCoreBodyTemperature(None, None, None, None, None, None)
}

pub fn us_core_body_weight_new() {
  UsCoreBodyWeight(None, None, None, None, None, None)
}

pub fn us_core_care_experience_preference_new() {
  UsCoreCareExperiencePreference(None, None, None, None, None, None)
}

pub fn us_core_careplan_new() {
  UsCoreCareplan(None, None, None, None)
}

pub fn us_core_careteam_new() {
  UsCoreCareteam(None, None, None)
}

pub fn us_core_condition_encounter_diagnosis_new() {
  UsCoreConditionEncounterDiagnosis(
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
  )
}

pub fn us_core_condition_problems_health_concerns_new() {
  UsCoreConditionProblemsHealthConcerns(
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
    None,
  )
}

pub fn us_core_coverage_new() {
  UsCoreCoverage(None)
}

pub fn us_core_diagnosticreport_lab_new() {
  UsCoreDiagnosticreportLab(None, None, None, None, None, None)
}

pub fn us_core_diagnosticreport_note_new() {
  UsCoreDiagnosticreportNote(None, None, None, None, None, None)
}

pub fn us_core_documentreference_new() {
  UsCoreDocumentreference(None, None, None, None, None, None, None)
}

pub fn us_core_encounter_new() {
  UsCoreEncounter(None, None, None, None, None, None, None, None, None, None)
}

pub fn us_core_goal_new() {
  UsCoreGoal(None, None, None, None)
}

pub fn us_core_head_circumference_new() {
  UsCoreHeadCircumference(None, None, None, None, None, None)
}

pub fn us_core_heart_rate_new() {
  UsCoreHeartRate(None, None, None, None, None, None)
}

pub fn us_core_immunization_new() {
  UsCoreImmunization(None, None, None)
}

pub fn us_core_implantable_device_new() {
  UsCoreImplantableDevice(None, None, None)
}

pub fn us_core_location_new() {
  UsCoreLocation(None, None, None, None, None)
}

pub fn us_core_medication_new() {
  UsCoreMedication
}

pub fn us_core_medicationdispense_new() {
  UsCoreMedicationdispense(None, None, None)
}

pub fn us_core_medicationrequest_new() {
  UsCoreMedicationrequest(None, None, None, None, None)
}

pub fn us_core_observation_clinical_result_new() {
  UsCoreObservationClinicalResult(None, None, None, None, None, None)
}

pub fn us_core_observation_lab_new() {
  UsCoreObservationLab(None, None, None, None, None, None)
}

pub fn us_core_observation_occupation_new() {
  UsCoreObservationOccupation(None, None, None, None, None, None)
}

pub fn us_core_observation_pregnancyintent_new() {
  UsCoreObservationPregnancyintent(None, None, None, None, None, None)
}

pub fn us_core_observation_pregnancystatus_new() {
  UsCoreObservationPregnancystatus(None, None, None, None, None, None)
}

pub fn us_core_observation_screening_assessment_new() {
  UsCoreObservationScreeningAssessment(None, None, None, None, None, None)
}

pub fn us_core_observation_sexual_orientation_new() {
  UsCoreObservationSexualOrientation(None, None, None, None, None, None)
}

pub fn us_core_organization_new() {
  UsCoreOrganization(None, None)
}

pub fn us_core_patient_new() {
  UsCorePatient(None, None, None, None, None, None, None, None)
}

pub fn us_core_practitioner_new() {
  UsCorePractitioner(None, None, None)
}

pub fn us_core_practitionerrole_new() {
  UsCorePractitionerrole(None, None)
}

pub fn us_core_procedure_new() {
  UsCoreProcedure(None, None, None, None)
}

pub fn us_core_provenance_new() {
  UsCoreProvenance
}

pub fn us_core_pulse_oximetry_new() {
  UsCorePulseOximetry(None, None, None, None, None, None)
}

pub fn us_core_questionnaireresponse_new() {
  UsCoreQuestionnaireresponse(None, None, None, None, None)
}

pub fn us_core_relatedperson_new() {
  UsCoreRelatedperson(None, None, None)
}

pub fn us_core_respiratory_rate_new() {
  UsCoreRespiratoryRate(None, None, None, None, None, None)
}

pub fn us_core_servicerequest_new() {
  UsCoreServicerequest(None, None, None, None, None, None)
}

pub fn us_core_simple_observation_new() {
  UsCoreSimpleObservation(None, None, None, None, None, None)
}

pub fn us_core_smokingstatus_new() {
  UsCoreSmokingstatus(None, None, None, None, None, None)
}

pub fn us_core_specimen_new() {
  UsCoreSpecimen(None, None)
}

pub fn us_core_treatment_intervention_preference_new() {
  UsCoreTreatmentInterventionPreference(None, None, None, None, None, None)
}

pub fn us_core_vital_signs_new() {
  UsCoreVitalSigns(None, None, None, None, None, None)
}
