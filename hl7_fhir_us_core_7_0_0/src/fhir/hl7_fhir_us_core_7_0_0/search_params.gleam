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

pub fn bundle_new() {
  Bundle(None, None, None, None, None)
}

pub fn endpoint_new() {
  Endpoint(None, None, None, None, None, None)
}

pub fn operationoutcome_new() {
  Operationoutcome
}
