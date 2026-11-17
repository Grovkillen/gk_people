# frozen_string_literal: true

# A person in a group of people. Added and removed are events on the group (records); the row itself is removed
# when the membership ends.
class GkPeopleGroupMember < ApplicationRecord
  self.table_name = 'gk_people_group_members'

  belongs_to :group, class_name: 'GkPeopleGroup'
  belongs_to :person, class_name: 'GkPeoplePerson'

  validates :person_id, uniqueness: { scope: :group_id }

  # the person as records' reference of a register person, and her account as records' reference when she has one;
  # never her name (records' convention)
  after_create_commit { GkPeople::PersonGroups.write(group, 'person_group_member_added', member_details) }
  after_destroy_commit { GkPeople::PersonGroups.write(group, 'person_group_member_removed', member_details) }

  private

  def member_details = { person: GkPeople::Refs.register_person(person_id), member: (person&.user_id ? GkPeople::Refs.person(person.user_id) : nil) }.compact
end
