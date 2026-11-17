# frozen_string_literal: true

# A change made while stepped up: which page did it, when, with what answer (GkPeople::Elevation)
class GkPeopleElevationAction < ApplicationRecord
  self.table_name = 'gk_people_elevation_actions'
  # an instant with its zone: what was done with elevated rights keeps its order
  GkPeopleInstant.attributes!(self, :at)

  belongs_to :elevation, class_name: 'GkPeopleElevation'
end
